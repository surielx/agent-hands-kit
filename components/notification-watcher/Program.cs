using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using Windows.UI.Notifications;
using Windows.UI.Notifications.Management;

// notifywatch (v2): resident watcher that captures Windows Notification Center
// toasts through the official UserNotificationListener API and appends them,
// one JSON object per line, to daily JSONL files under the store directory.
// AI-side readers (the msg-watch hook) poll those files; this tool never
// touches the apps themselves, so it works regardless of window state.
//
// Modes:
//   (none)     serve: resident loop (logon task). First run baselines the
//              notifications that already exist (records their ids as seen,
//              writes nothing) so history is never replayed.
//   --once     run a single sweep and exit (diagnostics / manual catch-up)
//   --status   print access status, current toast count and store summary
//
// Stop: end the task, or create a file named STOP in the store directory.

internal static class Program
{
    // Store directory: override with the NOTIFYWATCH_STORE environment variable;
    // default is %USERPROFILE%\notifywatch.
    private static readonly string StoreDir =
        Environment.GetEnvironmentVariable("NOTIFYWATCH_STORE")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "notifywatch");
    private static readonly string StatePath = Path.Combine(StoreDir, "state.json");
    private static readonly string LogPath = Path.Combine(StoreDir, "notifywatch.log");
    private static readonly string StopPath = Path.Combine(StoreDir, "STOP");
    private const int SweepIntervalMs = 10_000;
    private const int MaxSeenIds = 5000;
    private static readonly TimeZoneInfo LocalTz = TimeZoneInfo.Local;

    private static readonly object Gate = new();
    private static HashSet<uint> _seen = new();
    private static bool _dirty;
    // Keep stored JSON human/AI-readable (no \uXXXX escaping of +, Japanese…).
    private static readonly JsonSerializerOptions JsonOpts = new()
    { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    [DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    private static string NowIso() =>
        TimeZoneInfo.ConvertTime(DateTimeOffset.Now, LocalTz)
            .ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz");

    private static void Log(string msg)
    {
        try
        {
            Directory.CreateDirectory(StoreDir);
            var line = $"[{NowIso()}] {msg}\n";
            // simple rotation at ~1 MB
            var fi = new FileInfo(LogPath);
            if (fi.Exists && fi.Length > 1_000_000)
                File.Move(LogPath, LogPath + ".old", overwrite: true);
            File.AppendAllText(LogPath, line, new UTF8Encoding(false));
        }
        catch { /* logging must never kill the watcher */ }
    }

    private static void LoadState()
    {
        try
        {
            if (File.Exists(StatePath))
            {
                var doc = JsonDocument.Parse(File.ReadAllText(StatePath));
                if (doc.RootElement.TryGetProperty("seen", out var arr))
                    _seen = new HashSet<uint>(
                        arr.EnumerateArray().Select(e => e.GetUInt32()));
            }
        }
        catch (Exception ex) { Log($"state load failed: {ex.Message}"); }
    }

    private static void SaveState()
    {
        try
        {
            var ids = _seen.ToList();
            if (ids.Count > MaxSeenIds)
            {
                ids = ids.Skip(ids.Count - MaxSeenIds).ToList();
                _seen = new HashSet<uint>(ids);
            }
            var tmp = StatePath + ".tmp";
            File.WriteAllText(tmp,
                JsonSerializer.Serialize(new { seen = ids, updated = NowIso() }, JsonOpts),
                new UTF8Encoding(false));
            File.Move(tmp, StatePath, overwrite: true);
            _dirty = false;
        }
        catch (Exception ex) { Log($"state save failed: {ex.Message}"); }
    }

    private static (string appId, string appName) AppOf(UserNotification n)
    {
        string id = "", name = "";
        try { id = n.AppInfo?.AppUserModelId ?? ""; } catch { }
        try { name = n.AppInfo?.DisplayInfo?.DisplayName ?? ""; } catch { }
        if (string.IsNullOrEmpty(name)) name = id;
        return (id, name);
    }

    private static List<string> TextsOf(UserNotification n)
    {
        var texts = new List<string>();
        try
        {
            var bindings = n.Notification?.Visual?.Bindings;
            if (bindings != null && bindings.Count > 0)
            {
                NotificationBinding? chosen = null;
                foreach (var b in bindings)
                {
                    if (b.Template == "ToastGeneric") { chosen = b; break; }
                }
                chosen ??= bindings[0];
                foreach (var t in chosen.GetTextElements())
                    texts.Add(t.Text ?? "");
            }
        }
        catch { }
        return texts;
    }

    private static void AppendJsonl(UserNotification n, List<string> texts,
        string appId, string appName)
    {
        var created = TimeZoneInfo.ConvertTime(n.CreationTime, LocalTz);
        var file = Path.Combine(StoreDir,
            "notifications-" + created.ToString("yyyyMMdd") + ".jsonl");
        var rec = new Dictionary<string, object?>
        {
            ["received_at"] = created.ToString("yyyy-MM-dd'T'HH:mm:ss.fffzzz"),
            ["captured_at"] = NowIso(),
            ["id"] = n.Id,
            ["app_id"] = appId,
            ["app"] = appName,
            ["title"] = texts.Count > 0 ? texts[0] : "",
            ["texts"] = texts,
            ["tag"] = SafeTag(n),
            ["group"] = SafeGroup(n),
            ["kind"] = "toast",
            ["source"] = "user-notification-listener",
        };
        var json = JsonSerializer.Serialize(rec, JsonOpts);
        using var fs = new FileStream(file, FileMode.Append, FileAccess.Write,
            FileShare.Read);
        using var sw = new StreamWriter(fs, new UTF8Encoding(false));
        sw.WriteLine(json);
    }

    // The listener API does not expose Tag/Group for received notifications
    // (they exist only on the sender-side ToastNotification object), so these
    // stay empty; the fields are kept for format stability.
    private static string SafeTag(UserNotification n) => "";
    private static string SafeGroup(UserNotification n) => "";

    // One sweep: fetch current toasts, append the ones not seen before.
    // Returns number of newly recorded notifications.
    private static async Task<int> SweepAsync(UserNotificationListener listener,
        bool baseline)
    {
        IReadOnlyList<UserNotification> list;
        try
        {
            list = await listener.GetNotificationsAsync(NotificationKinds.Toast);
        }
        catch (Exception ex)
        {
            Log($"sweep failed: {ex.GetType().Name}: {ex.Message}");
            return 0;
        }
        int added = 0;
        lock (Gate)
        {
            foreach (var n in list)
            {
                if (_seen.Contains(n.Id)) continue;
                _seen.Add(n.Id);
                _dirty = true;
                if (baseline) continue;
                var (appId, appName) = AppOf(n);
                var texts = TextsOf(n);
                try
                {
                    AppendJsonl(n, texts, appId, appName);
                    added++;
                }
                catch (Exception ex)
                {
                    Log($"append failed id={n.Id}: {ex.Message}");
                }
            }
            if (_dirty) SaveState();
        }
        return added;
    }

    private static async Task<int> Main(string[] args)
    {
        Directory.CreateDirectory(StoreDir);
        string mode = args.Length > 0 ? args[0] : "serve";
        var listener = UserNotificationListener.Current;

        if (mode == "--status")
        {
            var st = await listener.RequestAccessAsync();
            Console.WriteLine("ACCESS=" + st);
            if (st == UserNotificationListenerAccessStatus.Allowed)
            {
                var l = await listener.GetNotificationsAsync(
                    NotificationKinds.Toast);
                Console.WriteLine("CURRENT_TOASTS=" + l.Count);
            }
            LoadState();
            Console.WriteLine("SEEN_IDS=" + _seen.Count);
            Console.WriteLine("STORE=" + StoreDir);
            return 0;
        }

        if (mode == "serve")
        {
            using var mutex = new Mutex(true, @"Global\AgentNotifyWatch",
                out bool createdNew);
            if (!createdNew) return 0; // already running
            try { ShowWindow(GetConsoleWindow(), 0); } catch { } // SW_HIDE
            return await ServeAsync(listener);
        }

        if (mode == "--once")
        {
            var st = await listener.RequestAccessAsync();
            if (st != UserNotificationListenerAccessStatus.Allowed)
            {
                Console.WriteLine("ACCESS=" + st);
                return 2;
            }
            LoadState();
            bool baseline = !File.Exists(StatePath + ".baselined");
            int added = await SweepAsync(listener, baseline);
            if (baseline) File.WriteAllText(StatePath + ".baselined", "1");
            Console.WriteLine($"ONCE added={added} baseline={baseline}");
            return 0;
        }

        Console.WriteLine("usage: notifywatch [serve|--once|--status]");
        return 1;
    }

    private static async Task<int> ServeAsync(UserNotificationListener listener)
    {
        Log("serve start");
        var status = await listener.RequestAccessAsync();
        Log("notification access: " + status);
        while (status != UserNotificationListenerAccessStatus.Allowed)
        {
            // Permission may be granted later in Settings; keep retrying.
            await Task.Delay(60_000);
            if (File.Exists(StopPath)) { Log("stop file: exit"); return 0; }
            status = await listener.RequestAccessAsync();
            Log("notification access retry: " + status);
        }

        LoadState();
        bool baselined = File.Exists(StatePath + ".baselined");
        int first = await SweepAsync(listener, baseline: !baselined);
        if (!baselined)
        {
            File.WriteAllText(StatePath + ".baselined", "1");
            Log($"baseline recorded ({_seen.Count} existing notifications marked seen)");
        }
        else if (first > 0) Log($"catch-up: {first} new");

        // Detection is polling-only by design: subscribing to
        // NotificationChanged from this non-dispatcher context was measured
        // to spin ~30 s of CPU at startup and then fail, while the AI-side
        // reader polls at 120 s anyway. A 10 s sweep is more than fast
        // enough and keeps the resident footprint minimal.
        while (true)
        {
            if (File.Exists(StopPath))
            {
                try { File.Delete(StopPath); } catch { }
                Log("stop file: exit");
                return 0;
            }
            await Task.Delay(SweepIntervalMs);
            int added = await SweepAsync(listener, baseline: false);
            if (added > 0) Log($"recorded {added} new notification(s)");
        }
    }
}
