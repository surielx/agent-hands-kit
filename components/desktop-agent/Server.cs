using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace DesktopAgent;

/// <summary>Resident server: listens on 127.0.0.1 with token auth, executes
/// desktop commands, logs every action, hosts the tray icon.</summary>
internal static class Server
{
    public const int Port = 8791;
    public static readonly string BaseDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "tools", "desktop-agent");
    public static string TokenPath => Path.Combine(BaseDir, "token.txt");
    public static string StopPath => Path.Combine(BaseDir, "STOP");
    public static string ShotsDir => Path.Combine(BaseDir, "shots");
    public static string LogDir => Path.Combine(BaseDir, "logs");
    public static string Token { get; private set; } = "";

    private static readonly SemaphoreSlim DesktopGate = new(1, 1);
    private static Form? _trayForm;
    private static HttpListener? _listener;
    private static volatile bool _running;

    public static string LoadOrCreateToken()
    {
        Directory.CreateDirectory(BaseDir);
        if (File.Exists(TokenPath))
        {
            string t = File.ReadAllText(TokenPath).Trim();
            if (t.Length >= 16) { Token = t; return t; }
        }
        Token = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(24)).ToLowerInvariant();
        File.WriteAllText(TokenPath, Token);
        return Token;
    }

    public static void Log(string action, string detail, bool ok, string? error = null)
    {
        try
        {
            Directory.CreateDirectory(LogDir);
            var rec = new JsonObject
            {
                ["ts"] = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fff"),
                ["action"] = action,
                ["detail"] = detail,
                ["ok"] = ok,
            };
            if (error != null) rec["error"] = error;
            File.AppendAllText(Path.Combine(LogDir, $"agent-{DateTime.Now:yyyyMMdd}.log"), rec.ToJsonString() + Environment.NewLine);
        }
        catch { /* logging must never break the agent */ }
    }

    public static int Run()
    {
        NativeMethods.timeBeginPeriod(1); // 1ms timer granularity for hold/sequence precision
        using var mutex = new Mutex(true, "DesktopAgentServeMutex", out bool createdNew);
        if (!createdNew)
        {
            Log("serve", "another instance is already running; exiting", false, "mutex held");
            return 2;
        }
        LoadOrCreateToken();
        _listener = new HttpListener();
        _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
        _listener.Start();
        _running = true;
        Log("serve", $"started pid={Environment.ProcessId} session={System.Diagnostics.Process.GetCurrentProcess().SessionId}", true);

        var httpThread = new Thread(ListenLoop) { IsBackground = true, Name = "http" };
        httpThread.Start();

        // Tray icon on the main (STA) thread.
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        _trayForm = new Form { ShowInTaskbar = false, WindowState = FormWindowState.Minimized, Opacity = 0, Size = new System.Drawing.Size(1, 1) };
        var tray = BuildTray();
        Application.Run(_trayForm);
        tray.Dispose();
        _running = false;
        try { _listener.Stop(); } catch { }
        NativeMethods.timeEndPeriod(1);
        Log("serve", "stopped", true);
        return 0;
    }

    private static NotifyIcon BuildTray()
    {
        var menu = new ContextMenuStrip();
        var statusItem = new ToolStripMenuItem("状態を表示");
        statusItem.Click += (_, _) =>
        {
            var (locked, _) = DesktopOps.GetLockState();
            double idle = DesktopOps.GetIdleSeconds();
            ShowBalloon($"Desktop Agent 動作中\nロック: {(locked ? "あり（操作不可）" : "なし")} / 無操作: {idle:F0} 秒");
        };
        var stopItem = new ToolStripMenuItem("エージェントを停止");
        stopItem.Click += (_, _) => Shutdown();
        menu.Items.Add(statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(stopItem);

        var icon = new NotifyIcon
        {
            Icon = DrawAgentIcon(),
            Text = "Desktop Agent（GUI操作エージェント）動作中",
            ContextMenuStrip = menu,
            Visible = true,
        };
        icon.DoubleClick += (_, _) => ShowBalloon("Desktop Agent が動作中です。操作はすべてログに記録されます。");
        _trayIcon = icon;
        return icon;
    }

    private static NotifyIcon? _trayIcon;
    private static void ShowBalloon(string text)
    {
        try
        {
            _trayIcon?.ShowBalloonTip(3000, "Desktop Agent", text, ToolTipIcon.Info);
        }
        catch { }
    }

    private static System.Drawing.Icon DrawAgentIcon()
    {
        var bmp = new System.Drawing.Bitmap(32, 32);
        using (var g = System.Drawing.Graphics.FromImage(bmp))
        {
            g.Clear(System.Drawing.Color.Transparent);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            using var brush = new System.Drawing.SolidBrush(System.Drawing.Color.FromArgb(0, 150, 220));
            g.FillEllipse(brush, 2, 2, 28, 28);
            using var pen = new System.Drawing.Pen(System.Drawing.Color.White, 3);
            g.DrawEllipse(pen, 9, 9, 14, 14);
        }
        IntPtr hIcon = bmp.GetHicon();
        var icon = System.Drawing.Icon.FromHandle(hIcon);
        return icon;
    }

    public static void Shutdown()
    {
        _running = false;
        try { _listener?.Stop(); } catch { }
        if (_trayForm != null)
        {
            try { _trayForm.BeginInvoke(() => { _trayIcon!.Visible = false; Application.Exit(); }); } catch { }
        }
    }

    /// <summary>Run an action on the tray UI thread (STA) — needed for clipboard.</summary>
    public static T InvokeOnUiThread<T>(Func<T> f)
    {
        if (_trayForm == null) throw new InvalidOperationException("tray/UI thread is not running");
        object? result = null;
        Exception? error = null;
        _trayForm.Invoke(() =>
        {
            try { result = f(); } catch (Exception ex) { error = ex; }
        });
        if (error != null) throw error;
        return (T)result!;
    }

    private static void ListenLoop()
    {
        while (_running)
        {
            HttpListenerContext ctx;
            try { ctx = _listener!.GetContext(); }
            catch { break; }
            ThreadPool.QueueUserWorkItem(_ => Handle(ctx));
        }
    }

    private static void Handle(HttpListenerContext ctx)
    {
        string action = "";
        try
        {
            string? token = ctx.Request.Headers["X-Token"];
            if (token == null || token != Token)
            {
                WriteJson(ctx, 401, new JsonObject { ["ok"] = false, ["error"] = "unauthorized: missing or bad token" });
                return;
            }
            string body;
            using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();
            var req = JsonNode.Parse(body)?.AsObject() ?? new JsonObject();
            action = req["action"]?.GetValue<string>() ?? "";

            bool readOnly = action is "ping" or "status" or "idle";
            if (!readOnly && File.Exists(StopPath))
            {
                Log(action, "", false, "refused: STOP file present");
                WriteJson(ctx, 200, new JsonObject { ["ok"] = false, ["error"] = "agent is stopped (STOP file present). Remove the STOP file to resume." });
                return;
            }

            JsonNode data;
            if (action is "ping" or "status" or "idle" or "stop-server")
            {
                data = DispatchMeta(action);
            }
            else
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                DesktopGate.Wait();
                try { data = DispatchDesktop(action, req); }
                finally { DesktopGate.Release(); }
                sw.Stop();
                if (data is JsonObject dobj)
                {
                    if (!dobj.ContainsKey("elapsedMs")) dobj["elapsedMs"] = sw.ElapsedMilliseconds;
                    // Observation digest: every response says what is in front now,
                    // so callers need fewer separate observation round trips.
                    try
                    {
                        var (fh, _, fproc, ftitle) = DesktopOps.ForegroundInfo();
                        dobj["fg"] = new JsonObject { ["process"] = fproc, ["title"] = ftitle, ["hwnd"] = fh };
                    }
                    catch { }
                }
            }
            bool loggable = action is not ("ping" or "status");
            if (loggable) Log(action, Summarize(req), true);
            WriteJson(ctx, 200, new JsonObject { ["ok"] = true, ["data"] = data });
        }
        catch (Exception ex)
        {
            if (action.Length > 0) Log(action, "", false, ex.Message);
            try { WriteJson(ctx, 200, new JsonObject { ["ok"] = false, ["error"] = ex.GetType().Name + ": " + ex.Message }); } catch { }
        }
    }

    private static string Summarize(JsonObject req)
    {
        var parts = new List<string>();
        foreach (var kv in req)
        {
            if (kv.Key == "action" || kv.Key == "text") continue;
            string v = kv.Value?.ToJsonString() ?? "";
            if (v.Length > 80) v = v[..80] + "…";
            parts.Add($"{kv.Key}={v}");
        }
        if (req.ContainsKey("text")) parts.Add($"text=<{req["text"]?.GetValue<string>().Length ?? 0} chars>");
        return string.Join(" ", parts);
    }

    private static JsonNode DispatchMeta(string action)
    {
        switch (action)
        {
            case "ping":
                return new JsonObject { ["pong"] = true };
            case "idle":
                return new JsonObject { ["idleSeconds"] = Math.Round(DesktopOps.GetIdleSeconds(), 1) };
            case "stop-server":
                Log("stop-server", "shutdown requested via client", true);
                var t = new Thread(() => { Thread.Sleep(300); Shutdown(); }) { IsBackground = true };
                t.Start();
                return new JsonObject { ["stopping"] = true };
            case "status":
            {
                var (locked, desk) = DesktopOps.GetLockState();
                return new JsonObject
                {
                    ["serverVersion"] = "1.1.0",
                    ["pid"] = Environment.ProcessId,
                    ["sessionId"] = System.Diagnostics.Process.GetCurrentProcess().SessionId,
                    ["user"] = Environment.UserName,
                    ["locked"] = locked,
                    ["inputDesktop"] = desk,
                    ["idleSeconds"] = Math.Round(DesktopOps.GetIdleSeconds(), 1),
                    ["stopFilePresent"] = File.Exists(StopPath),
                    ["snapshotCacheHwnd"] = UiaOps.CacheHwnd,
                    ["workingSetMB"] = Math.Round(System.Diagnostics.Process.GetCurrentProcess().WorkingSet64 / 1048576.0, 1),
                    ["privateMemoryMB"] = Math.Round(System.Diagnostics.Process.GetCurrentProcess().PrivateMemorySize64 / 1048576.0, 1),
                    ["startedWithToken"] = true,
                };
            }
            default:
                throw new InvalidOperationException($"unknown action '{action}'");
        }
    }

    private static void EnsureUnlocked(string action)
    {
        // A single "locked" reading can be a transient secure-desktop flicker
        // (observed 2026-11-12: reported locked while the desktop was usable,
        // which stopped work needlessly). Re-check over ~1.6 s before refusing.
        string desk = "";
        for (int attempt = 0; attempt < 4; attempt++)
        {
            var (locked, d) = DesktopOps.GetLockState();
            desk = d;
            if (!locked) return;
            if (attempt < 3) Thread.Sleep(400);
        }
        throw new InvalidOperationException($"desktop is locked or on the secure desktop (input desktop = {desk}, confirmed over 4 checks spanning ~1.6s); refusing '{action}'");
    }

    private static string Req(JsonObject req, string key) =>
        req[key]?.GetValue<string>() ?? throw new InvalidOperationException($"missing parameter '{key}'");

    private static string? Opt(JsonObject req, string key) => req[key]?.GetValue<string>();

    private static int OptInt(JsonObject req, string key, int fallback) =>
        req[key] != null ? req[key]!.GetValue<int>() : fallback;

    private static bool OptBool(JsonObject req, string key, bool fallback) =>
        req[key] != null ? req[key]!.GetValue<bool>() : fallback;

    private static JsonNode DispatchDesktop(string action, JsonObject req)
    {
        switch (action)
        {
            case "monitors":
            {
                var arr = new JsonArray();
                foreach (var m in DesktopOps.GetMonitors()) arr.Add(JsonNode.Parse(JsonSerializer.Serialize(m)));
                return new JsonObject { ["monitors"] = arr };
            }
            case "windows":
            {
                var arr = new JsonArray();
                foreach (var w in DesktopOps.GetWindows())
                    arr.Add(new JsonObject
                    {
                        ["hwnd"] = w.Hwnd, ["title"] = w.Title, ["className"] = w.ClassName,
                        ["pid"] = w.Pid, ["process"] = w.ProcessName,
                        ["x"] = w.X, ["y"] = w.Y, ["width"] = w.Width, ["height"] = w.Height,
                        ["minimized"] = w.Minimized, ["foreground"] = w.Foreground, ["cloaked"] = w.Cloaked,
                    });
                return new JsonObject { ["windows"] = arr };
            }
            case "screenshot":
            {
                EnsureUnlocked(action);
                int x, y, w, h;
                string scope;
                if (req["rect"] is JsonArray ra)
                {
                    x = ra[0]!.GetValue<int>(); y = ra[1]!.GetValue<int>(); w = ra[2]!.GetValue<int>(); h = ra[3]!.GetValue<int>();
                    scope = "rect";
                }
                else if (Opt(req, "window") is string sel)
                {
                    var win = DesktopOps.ResolveWindow(sel);
                    if (win.Minimized) throw new InvalidOperationException($"window '{win.Title}' is minimized; focus it first");
                    x = win.X; y = win.Y; w = win.Width; h = win.Height;
                    scope = "window:" + win.Title;
                }
                else
                {
                    (x, y, w, h) = DesktopOps.VirtualScreenRect();
                    scope = "full";
                }
                string format = Opt(req, "format") ?? "png";
                int quality = OptInt(req, "quality", 85);
                double scale = req["scale"] != null ? req["scale"]!.GetValue<double>() : 1.0;
                if (scale <= 0 || scale > 1) throw new InvalidOperationException("scale must be in (0, 1]");
                var shot = DesktopOps.CaptureScreenshot(x, y, w, h, Opt(req, "out"), ShotsDir, format, quality, scale);
                return new JsonObject
                {
                    ["path"] = shot.Path, ["scope"] = scope, ["x"] = x, ["y"] = y,
                    ["srcWidth"] = w, ["srcHeight"] = h,
                    ["width"] = shot.Width, ["height"] = shot.Height,
                    ["format"] = shot.Format, ["captureMs"] = shot.ElapsedMs,
                    ["bytes"] = new FileInfo(shot.Path).Length,
                };
            }
            case "snapshot":
            {
                EnsureUnlocked(action);
                IntPtr hwnd;
                if (Opt(req, "window") is string sel) hwnd = new IntPtr(DesktopOps.ResolveWindow(sel).Hwnd);
                else
                {
                    hwnd = NativeMethods.GetForegroundWindow();
                    if (hwnd == IntPtr.Zero) throw new InvalidOperationException("no foreground window");
                }
                int depth = OptInt(req, "depth", 10);
                int max = OptInt(req, "max", 300);
                int[]? region = null;
                if (req["region"] is JsonArray regArr)
                {
                    if (regArr.Count != 4) throw new InvalidOperationException("region must be [x,y,w,h]");
                    region = regArr.Select(v => v!.GetValue<int>()).ToArray();
                }
                bool wantDiff = OptBool(req, "diff", false);
                var snap = UiaOps.Snapshot(hwnd, depth, max, region, wantDiff);
                var data = new JsonObject
                {
                    ["window"] = JsonNode.Parse(JsonSerializer.Serialize(snap.Window)),
                    ["elements"] = ToJsonArr(snap.Elements),
                };
                if (snap.Changed != null) data["changed"] = ToJsonArr(snap.Changed);
                if (snap.Removed != null) data["removed"] = ToJsonArr(snap.Removed);
                return data;
            }
            case "focus":
            {
                EnsureUnlocked(action);
                var win = DesktopOps.ResolveWindow(Req(req, "window"));
                bool okfg = DesktopOps.FocusWindow(new IntPtr(win.Hwnd));
                return new JsonObject { ["hwnd"] = win.Hwnd, ["title"] = win.Title, ["foregroundNow"] = okfg };
            }
            case "click":
            {
                EnsureUnlocked(action);
                string button = Opt(req, "button") ?? "left";
                int count = OptInt(req, "count", 1);
                if (Opt(req, "element") is string eid)
                {
                    var r = UiaOps.ClickElement(eid, button, count);
                    return JsonNode.Parse(JsonSerializer.Serialize(r))!;
                }
                if (req["ix"] != null)
                {
                    // Image coordinates: the caller points at a spot in an image of
                    // size imgW x imgH (e.g. a downscaled screenshot); the server
                    // converts to real pixels, so callers never do pixel math.
                    int iw = Req2(req, "imgW"), ih = Req2(req, "imgH");
                    double ix = req["ix"]!.GetValue<double>(), iy = req["iy"]!.GetValue<double>();
                    var (vx, vy, vw, vh) = DesktopOps.VirtualScreenRect();
                    int rx = vx + (int)Math.Round(ix * vw / iw);
                    int ry = vy + (int)Math.Round(iy * vh / ih);
                    DesktopOps.ClickAt(rx, ry, button, count);
                    return new JsonObject { ["how"] = "image-coordinate", ["x"] = rx, ["y"] = ry, ["button"] = button, ["count"] = count };
                }
                int x = OptInt(req, "x", int.MinValue), y = OptInt(req, "y", int.MinValue);
                if (x == int.MinValue || y == int.MinValue) throw new InvalidOperationException("click needs 'element' or 'x'+'y'");
                DesktopOps.ClickAt(x, y, button, count);
                return new JsonObject { ["how"] = "coordinate", ["x"] = x, ["y"] = y, ["button"] = button, ["count"] = count };
            }
            case "drag":
            {
                EnsureUnlocked(action);
                DesktopOps.Drag(Req2(req, "x1"), Req2(req, "y1"), Req2(req, "x2"), Req2(req, "y2"), Opt(req, "button") ?? "left");
                return new JsonObject { ["dragged"] = true };
            }
            case "scroll":
            {
                EnsureUnlocked(action);
                DesktopOps.ScrollAt(Req2(req, "x"), Req2(req, "y"), OptInt(req, "delta", -360), OptBool(req, "horizontal", false));
                return new JsonObject { ["scrolled"] = true };
            }
            case "move":
            {
                EnsureUnlocked(action);
                if (OptBool(req, "relative", false))
                {
                    DesktopOps.MoveRelative(Req2(req, "x"), Req2(req, "y"));
                    return new JsonObject { ["moved"] = "relative" };
                }
                DesktopOps.MoveMouse(Req2(req, "x"), Req2(req, "y"));
                return new JsonObject { ["moved"] = true };
            }
            case "path":
            {
                EnsureUnlocked(action);
                if (req["points"] is not JsonArray pts || pts.Count == 0)
                    throw new InvalidOperationException("path needs 'points': [[x,y],...]");
                var list = new List<(int, int)>();
                foreach (var pt in pts)
                {
                    var a = pt as JsonArray ?? throw new InvalidOperationException("path point must be [x,y]");
                    list.Add((a[0]!.GetValue<int>(), a[1]!.GetValue<int>()));
                }
                int duration = OptInt(req, "duration", 500);
                var swp = System.Diagnostics.Stopwatch.StartNew();
                DesktopOps.MousePath(list, duration);
                swp.Stop();
                return new JsonObject { ["points"] = list.Count, ["durationMs"] = duration, ["actualMs"] = swp.ElapsedMilliseconds };
            }
            case "keydown":
            {
                EnsureUnlocked(action);
                DesktopOps.KeyDown(Req(req, "key"));
                return new JsonObject { ["down"] = Req(req, "key") };
            }
            case "keyup":
            {
                EnsureUnlocked(action);
                DesktopOps.KeyUp(Req(req, "key"));
                return new JsonObject { ["up"] = Req(req, "key") };
            }
            case "hold":
            {
                EnsureUnlocked(action);
                int ms = OptInt(req, "ms", 0);
                if (ms <= 0 || ms > 60000) throw new InvalidOperationException("hold 'ms' must be 1..60000");
                long actual = DesktopOps.HoldKey(Req(req, "key"), ms);
                return new JsonObject { ["held"] = Req(req, "key"), ["requestedMs"] = ms, ["actualMs"] = actual, ["errorMs"] = actual - ms };
            }
            case "raw":
            {
                EnsureUnlocked(action);
                if (req["events"] is not JsonArray evs) throw new InvalidOperationException("raw needs 'events' array");
                int n = DesktopOps.RawSend(evs);
                return new JsonObject { ["sent"] = n };
            }
            case "sequence":
            {
                EnsureUnlocked(action);
                if (req["steps"] is not JsonArray steps) throw new InvalidOperationException("sequence needs 'steps' array");
                return RunSequence(steps);
            }
            case "type":
            {
                EnsureUnlocked(action);
                string text = Req(req, "text");
                DesktopOps.TypeText(text);
                return new JsonObject { ["typedChars"] = text.Length };
            }
            case "key":
            {
                EnsureUnlocked(action);
                DesktopOps.PressChord(Req(req, "chord"));
                return new JsonObject { ["pressed"] = Req(req, "chord") };
            }
            case "setvalue":
            {
                EnsureUnlocked(action);
                var r = UiaOps.SetValue(Req(req, "element"), Req(req, "text"));
                return JsonNode.Parse(JsonSerializer.Serialize(r))!;
            }
            case "scrollintoview":
            {
                EnsureUnlocked(action);
                var r = UiaOps.ScrollIntoView(Req(req, "element"));
                return JsonNode.Parse(JsonSerializer.Serialize(r))!;
            }
            case "launch":
            {
                EnsureUnlocked(action);
                int pid = DesktopOps.LaunchApp(Req(req, "app"), Opt(req, "args"));
                return new JsonObject { ["pid"] = pid, ["app"] = Req(req, "app") };
            }
            case "clipboard-get":
            {
                EnsureUnlocked(action);
                string text = InvokeOnUiThread(() => System.Windows.Forms.Clipboard.ContainsText() ? System.Windows.Forms.Clipboard.GetText() : "");
                return new JsonObject { ["text"] = text };
            }
            case "clipboard-set":
            {
                EnsureUnlocked(action);
                string text = Req(req, "text");
                InvokeOnUiThread<object?>(() => { System.Windows.Forms.Clipboard.SetText(text); return null; });
                Log("clipboard-set", $"<{text.Length} chars>", true);
                return new JsonObject { ["set"] = true, ["chars"] = text.Length };
            }
            case "paste":
            {
                // One server-side operation: set the clipboard IN the interactive
                // session, read it back to verify, and only then press Ctrl+V.
                // (Clipboards are per-session; setting one from another session
                // silently pastes stale content -- observed 2026-11-12.)
                EnsureUnlocked(action);
                string text = Req(req, "text");
                InvokeOnUiThread<object?>(() =>
                {
                    System.Windows.Forms.Clipboard.SetText(text);
                    string back = System.Windows.Forms.Clipboard.ContainsText() ? System.Windows.Forms.Clipboard.GetText() : "";
                    if (back != text) throw new InvalidOperationException("clipboard readback mismatch; refusing to paste");
                    return null;
                });
                DesktopOps.PressChord("ctrl+v");
                Log("paste", $"<{text.Length} chars>", true);
                return new JsonObject { ["pasted"] = true, ["chars"] = text.Length, ["verified"] = true };
            }
            default:
                throw new InvalidOperationException($"unknown action '{action}'");
        }
    }

    private static JsonArray ToJsonArr(List<Dictionary<string, object>> items)
    {
        var arr = new JsonArray();
        foreach (var e in items) arr.Add(JsonNode.Parse(JsonSerializer.Serialize(e)));
        return arr;
    }

    /// <summary>Evaluate a condition object against the live desktop.
    /// Keys (all specified keys must hold): "process" = foreground process name
    /// equals, "window" = foreground title contains, "uiaText" = some element
    /// name in the foreground window contains the text.</summary>
    private static bool ConditionMet(JsonObject cond, out string observed)
    {
        var (hwnd, _, proc, title) = DesktopOps.ForegroundInfo();
        observed = $"process={proc} title=\"{title}\"";
        if (cond["process"] is JsonNode pn && !string.Equals(proc, pn.GetValue<string>(), StringComparison.OrdinalIgnoreCase)) return false;
        if (cond["window"] is JsonNode wn && !title.Contains(wn.GetValue<string>(), StringComparison.OrdinalIgnoreCase)) return false;
        if (cond["uiaText"] is JsonNode un)
        {
            if (hwnd == 0 || !UiaOps.ContainsText(new IntPtr(hwnd), un.GetValue<string>())) return false;
        }
        return true;
    }

    private static bool WaitForCondition(JsonObject cond, int timeoutMs, out string observed)
    {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        while (true)
        {
            if (ConditionMet(cond, out observed)) return true;
            if (sw.ElapsedMilliseconds >= timeoutMs) return false;
            Thread.Sleep(150);
        }
    }

    private static readonly HashSet<string> StepControlKeys = new(StringComparer.Ordinal)
    {
        "do", "delay", "precond", "expect", "precondTimeoutMs", "expectTimeoutMs",
    };

    /// <summary>Execute a batch of steps server-side with precise timing.
    /// Each step: {"do":"<action>", ...params of that action..., "delay": ms to wait before the step}.
    /// A step may also carry "precond" (condition object waited on BEFORE the
    /// step runs) and "expect" (condition object waited on AFTER it runs), with
    /// optional "precondTimeoutMs" (default 3000) / "expectTimeoutMs" (default
    /// 5000). Waiting on observable state replaces fixed sleeps and blind clicks.
    /// Timing is scheduled on a Stopwatch timeline and the report includes the
    /// measured start offset of every step so accuracy is auditable.</summary>
    private static JsonObject RunSequence(JsonArray steps)
    {
        var report = new JsonArray();
        var total = System.Diagnostics.Stopwatch.StartNew();
        int executed = 0;
        string? failedError = null;
        int failedAt = -1;

        for (int i = 0; i < steps.Count; i++)
        {
            var stepObj = steps[i] as JsonObject ?? new JsonObject();
            string doAction = stepObj["do"]?.GetValue<string>() ?? "";
            int delay = stepObj["delay"]?.GetValue<int>() ?? 0;
            if (delay > 0) DesktopOps.PreciseWait(delay);
            double startMs = total.Elapsed.TotalMilliseconds;
            var stepSw = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                if (doAction is "sequence" or "stop-server" or "ping" or "status")
                    throw new InvalidOperationException($"action '{doAction}' is not allowed inside a sequence");
                // Precondition: wait for the desktop to be in the expected
                // state BEFORE acting, instead of fixed sleeps and blind clicks.
                if (stepObj["precond"] is JsonObject pre)
                {
                    int preTmo = stepObj["precondTimeoutMs"]?.GetValue<int>() ?? 3000;
                    if (!WaitForCondition(pre, preTmo, out string preObs))
                        throw new InvalidOperationException($"precondition not met within {preTmo}ms: {pre.ToJsonString()} (observed: {preObs})");
                }
                var sub = new JsonObject();
                foreach (var kv in stepObj)
                {
                    if (StepControlKeys.Contains(kv.Key)) continue;
                    sub[kv.Key] = kv.Value?.DeepClone();
                }
                DispatchDesktop(doAction, sub);
                // Expectation: the step only counts as done once its observable
                // effect actually arrived.
                if (stepObj["expect"] is JsonObject exp)
                {
                    int expTmo = stepObj["expectTimeoutMs"]?.GetValue<int>() ?? 5000;
                    if (!WaitForCondition(exp, expTmo, out string expObs))
                        throw new InvalidOperationException($"expectation not met within {expTmo}ms: {exp.ToJsonString()} (observed: {expObs})");
                }
                executed++;
            }
            catch (Exception ex)
            {
                failedAt = i;
                failedError = ex.Message;
                stepSw.Stop();
                report.Add(new JsonObject
                {
                    ["i"] = i, ["do"] = doAction, ["startMs"] = Math.Round(startMs, 2),
                    ["durationMs"] = Math.Round(stepSw.Elapsed.TotalMilliseconds, 2),
                    ["ok"] = false, ["error"] = ex.Message,
                });
                break;
            }
            stepSw.Stop();
            report.Add(new JsonObject
            {
                ["i"] = i, ["do"] = doAction, ["startMs"] = Math.Round(startMs, 2),
                ["durationMs"] = Math.Round(stepSw.Elapsed.TotalMilliseconds, 2),
                ["ok"] = true,
            });
        }
        total.Stop();
        Log("sequence", $"steps={steps.Count} executed={executed} totalMs={total.ElapsedMilliseconds:F1}" + (failedError != null ? $" FAILED at {failedAt}: {failedError}" : ""), failedError == null, failedError);
        var result = new JsonObject
        {
            ["steps"] = report,
            ["executed"] = executed,
            ["totalMs"] = Math.Round(total.Elapsed.TotalMilliseconds, 2),
        };
        if (failedError != null) { result["failedAt"] = failedAt; result["error"] = failedError; }
        return result;
    }

    private static int Req2(JsonObject req, string key) =>
        req[key]?.GetValue<int>() ?? throw new InvalidOperationException($"missing parameter '{key}'");

    private static void WriteJson(HttpListenerContext ctx, int status, JsonObject payload)
    {
        var bytes = Encoding.UTF8.GetBytes(payload.ToJsonString());
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.Close();
    }
}
