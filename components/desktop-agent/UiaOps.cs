using System.Windows.Automation;

namespace DesktopAgent;

/// <summary>UI Automation snapshot, pruned to interactive/content elements so
/// responses stay small, with compact field names, optional region scoping,
/// and diffing against the previous snapshot of the same window.
/// Element IDs (e1, e2, …) refer to the latest snapshot (full or diff-merged view)
/// and are what click/setvalue accept.</summary>
internal static class UiaOps
{
    private static readonly object Gate = new();
    private static Dictionary<string, AutomationElement> _cache = new();
    private static long _cacheHwnd;
    // Per-window last snapshot for diff: pathKey -> (id, signature)
    private static readonly Dictionary<long, Dictionary<string, (string id, string sig)>> _lastByWindow = new();

    // Patterns that make an element actionable, with short codes for output.
    private static readonly (AutomationPattern pattern, string code)[] ActionPatterns =
    {
        (InvokePattern.Pattern, "invoke"),
        (ValuePattern.Pattern, "value"),
        (TogglePattern.Pattern, "toggle"),
        (SelectionItemPattern.Pattern, "select"),
        (ExpandCollapsePattern.Pattern, "expand"),
        (RangeValuePattern.Pattern, "range"),
        (ScrollItemPattern.Pattern, "scrollitem"),
    };

    private static readonly AutomationPattern[] InfoPatterns =
    {
        InvokePattern.Pattern, ValuePattern.Pattern, TogglePattern.Pattern,
        SelectionItemPattern.Pattern, ExpandCollapsePattern.Pattern,
        RangeValuePattern.Pattern, ScrollItemPattern.Pattern, TextPattern.Pattern,
        WindowPattern.Pattern, SelectionPattern.Pattern, GridPattern.Pattern,
        TablePattern.Pattern, ScrollPattern.Pattern, TransformPattern.Pattern,
    };

    // Control types whose named instances carry information even without patterns.
    private static readonly HashSet<string> ContentTypes = new(StringComparer.Ordinal)
    {
        "Text", "Edit", "Document", "Header", "HeaderItem", "DataItem", "ListItem",
        "TreeItem", "MenuItem", "TabItem", "Hyperlink", "Image", "Custom",
    };

    private sealed class Node
    {
        public required AutomationElement El;
        public List<Node> Children = new();
        public string Type = "?";
        public string Name = "";
        public string Aid = "";
        public System.Windows.Rect Rect = System.Windows.Rect.Empty;
        public bool Enabled = true, Offscreen, Focused, Focusable;
        public List<string> Patterns = new();
        public string Value = "";
        public string Toggle = "";
        public bool Selected;
        public bool Interesting;
    }

    public sealed class SnapshotResult
    {
        public required Dictionary<string, object> Window { get; init; }
        public required List<Dictionary<string, object>> Elements { get; init; }
        public List<Dictionary<string, object>>? Changed { get; init; }
        public List<Dictionary<string, object>>? Removed { get; init; }
        public required bool IsDiff { get; init; }
        public required int RawCount { get; init; }
        public required bool Truncated { get; init; }
    }

    /// <summary>Bounded breadth-first search: does any element in the window
    /// carry a Name containing the text? Used for sequence expect/precond
    /// conditions. Read-only; capped so it stays cheap on large trees.</summary>
    public static bool ContainsText(IntPtr hwnd, string text)
    {
        var root = AutomationElement.FromHandle(hwnd);
        if (root == null) return false;
        var queue = new Queue<(AutomationElement el, int depth)>();
        queue.Enqueue((root, 0));
        int seen = 0;
        while (queue.Count > 0)
        {
            var (el, depth) = queue.Dequeue();
            if (++seen > 800) break;
            string name = "";
            try { name = el.Current.Name ?? ""; } catch { }
            if (name.Length > 0 && name.Contains(text, StringComparison.OrdinalIgnoreCase)) return true;
            if (depth >= 12) continue;
            try
            {
                var child = TreeWalker.ControlViewWalker.GetFirstChild(el);
                while (child != null)
                {
                    queue.Enqueue((child, depth + 1));
                    child = TreeWalker.ControlViewWalker.GetNextSibling(child);
                }
            }
            catch { }
        }
        return false;
    }

    public static SnapshotResult Snapshot(IntPtr hwnd, int maxDepth = 10, int maxElements = 300,
                                          int[]? region = null, bool diff = false)
    {
        var rootEl = AutomationElement.FromHandle(hwnd)
            ?? throw new InvalidOperationException("UI Automation could not attach to the window");
        int rawCount = 0;
        bool truncated = false;

        Node Build(AutomationElement el, int depth)
        {
            rawCount++;
            var node = new Node { El = el };
            AutomationElement.AutomationElementInformation cur = default;
            bool hasCur;
            try { cur = el.Current; hasCur = true; } catch { hasCur = false; }
            if (hasCur)
            {
                node.Type = Safe(() => cur.ControlType.ProgrammaticName.Replace("ControlType.", ""), "?");
                node.Name = Safe(() => cur.Name, "") ?? "";
                node.Aid = Safe(() => cur.AutomationId, "") ?? "";
                node.Rect = Safe(() => cur.BoundingRectangle, System.Windows.Rect.Empty);
                node.Enabled = Safe(() => cur.IsEnabled, false);
                node.Offscreen = Safe(() => cur.IsOffscreen, false);
                node.Focused = Safe(() => cur.HasKeyboardFocus, false);
                node.Focusable = Safe(() => cur.IsKeyboardFocusable, false);
            }
            foreach (var (pat, code) in ActionPatterns)
                if (el.TryGetCurrentPattern(pat, out object _)) node.Patterns.Add(code);
            if (el.TryGetCurrentPattern(TextPattern.Pattern, out object _)) node.Patterns.Add("text");
            if (el.TryGetCurrentPattern(ValuePattern.Pattern, out object vp))
            {
                string v = Safe(() => ((ValuePattern)vp).Current.Value, "") ?? "";
                node.Value = v.Length > 120 ? v[..120] + "…" : v;
            }
            if (el.TryGetCurrentPattern(TogglePattern.Pattern, out object tp))
                node.Toggle = Safe(() => ((TogglePattern)tp).Current.ToggleState.ToString(), "");
            if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out object sp))
                node.Selected = Safe(() => ((SelectionItemPattern)sp).Current.IsSelected, false);

            node.Interesting =
                node.Patterns.Count > 0 ||
                (node.Focusable && node.Enabled) ||
                (node.Name.Length > 0 && ContentTypes.Contains(node.Type));

            // WinUI popup hosts (keytip badges, tooltip hosts) flood the tree
            // with transient noise after Alt/menu interactions: prune the subtree.
            if (node.Name == "PopupHost") { node.Interesting = false; return node; }

            if (depth >= maxDepth || rawCount >= 1500)
            {
                if (rawCount >= 1500) truncated = true;
                return node;
            }
            AutomationElement? child = null;
            try { child = TreeWalker.ControlViewWalker.GetFirstChild(el); } catch (ElementNotAvailableException) { }
            while (child != null)
            {
                node.Children.Add(Build(child, depth + 1));
                if (rawCount >= 1500) { truncated = true; break; }
                AutomationElement? next = null;
                try { next = TreeWalker.ControlViewWalker.GetNextSibling(child); } catch (ElementNotAvailableException) { }
                child = next;
            }
            return node;
        }

        var root = Build(rootEl, 0);

        bool IntersectsRegion(Node n)
        {
            if (region == null) return true;
            if (n.Rect.IsEmpty) return false;
            var r = new System.Windows.Rect(region[0], region[1], region[2], region[3]);
            return r.IntersectsWith(n.Rect);
        }

        // Bottom-up prune: keep node if interesting (and in region scope) or any child kept.
        bool Keep(Node n, bool isRoot)
        {
            bool anyChildKept = false;
            foreach (var c in n.Children) if (Keep(c, false)) anyChildKept = true;
            n.Interesting = isRoot || anyChildKept || (n.Interesting && IntersectsRegion(n));
            return n.Interesting;
        }
        Keep(root, true);

        // Previous snapshot map for this window (IDs are kept stable per path key,
        // so unchanged elements keep their IDs across snapshots).
        long hwndVal = hwnd.ToInt64();
        Dictionary<string, (string id, string sig)>? prevMap;
        lock (Gate) { _lastByWindow.TryGetValue(hwndVal, out prevMap); }
        int freshCounter = 0;
        if (prevMap != null)
            foreach (var v in prevMap.Values)
                if (v.id.StartsWith("e") && int.TryParse(v.id.AsSpan(1), out int num) && num > freshCounter) freshCounter = num;

        // Flatten kept nodes, assign stable IDs and diff path keys.
        var newCache = new Dictionary<string, AutomationElement>();
        var flat = new List<(Node node, Dictionary<string, object> rec, string key, string sig)>();
        int keptCount = 0;
        bool limitHit = false;

        void Flatten(Node n, string parentId, int depth, string parentKey, Dictionary<string, int> siblingCounts)
        {
            if (limitHit) return;
            if (keptCount >= maxElements) { limitHit = true; truncated = true; return; }

            // The root's key must not depend on the window title (it changes as
            // soon as a document is edited), or every descendant key breaks.
            string discrim = depth == 0 ? "root" : (n.Aid.Length > 0 ? n.Aid : (n.Name.Length > 0 ? n.Name : n.Type));
            string baseKey = n.Type + ":" + discrim;
            siblingCounts.TryGetValue(baseKey, out int occ);
            siblingCounts[baseKey] = occ + 1;
            string key = parentKey + "/" + baseKey + "@" + occ;

            string id;
            if (prevMap != null && prevMap.TryGetValue(key, out var oldEntry)) id = oldEntry.id;
            else { freshCounter++; id = "e" + freshCounter; }
            keptCount++;
            newCache[id] = n.El;

            string rStr = n.Rect.IsEmpty ? "-" : $"{(int)n.Rect.X},{(int)n.Rect.Y},{(int)n.Rect.Width},{(int)n.Rect.Height}";
            string sig = string.Join("|", n.Type, n.Name, rStr, n.Enabled ? "1" : "0", n.Value, n.Toggle, n.Selected ? "1" : "0");

            flat.Add((n, DescribeKept(n, id, parentId, depth), key, sig));
            var childCounts = new Dictionary<string, int>();
            foreach (var c in n.Children)
            {
                if (!c.Interesting) continue;
                Flatten(c, id, depth + 1, key, childCounts);
                if (limitHit) return;
            }
        }

        Flatten(root, "", 0, "", new Dictionary<string, int>());

        // Commit cache + diff bookkeeping
        List<Dictionary<string, object>> elements;
        List<Dictionary<string, object>>? changed = null;
        List<Dictionary<string, object>>? removed = null;
        bool isDiff = false;
        lock (Gate)
        {
            _cache = newCache;
            _cacheHwnd = hwndVal;
            var newMap = new Dictionary<string, (string, string)>();
            foreach (var f in flat) newMap[f.key] = (f.rec["id"]!.ToString()!, f.sig);

            if (diff && prevMap != null)
            {
                isDiff = true;
                elements = new List<Dictionary<string, object>>();
                changed = new List<Dictionary<string, object>>();
                removed = new List<Dictionary<string, object>>();
                foreach (var f in flat)
                {
                    if (!prevMap.TryGetValue(f.key, out var old)) elements.Add(f.rec);                    // added
                    else if (old.Item2 != f.sig) { f.rec["changed"] = true; changed.Add(f.rec); }         // changed
                }
                foreach (var kv in prevMap)
                    if (!newMap.ContainsKey(kv.Key))
                        removed.Add(new Dictionary<string, object> { ["wasId"] = kv.Value.Item1, ["key"] = kv.Key });
            }
            else
            {
                elements = flat.Select(f => f.rec).ToList();
            }
            _lastByWindow[hwndVal] = newMap;
        }

        var wr = root.Rect;
        var win = new Dictionary<string, object>
        {
            ["hwnd"] = hwndVal,
            ["name"] = root.Name,
            ["className"] = Safe(() => rootEl.Current.ClassName, ""),
            ["processId"] = Safe(() => rootEl.Current.ProcessId, 0),
            ["x"] = (int)wr.X, ["y"] = (int)wr.Y, ["width"] = (int)wr.Width, ["height"] = (int)wr.Height,
            ["rawElements"] = rawCount,
            ["keptElements"] = flat.Count,
            ["truncated"] = truncated,
            ["diff"] = isDiff,
            ["legend"] = "id, p=parent, t=type, n=name, r=[x,y,w,h], en=0 if disabled, off=1 if offscreen, foc=1 if focused, pat=patterns, val=value, aid=automationId",
            ["note"] = "Element IDs are stable across snapshots of the same window while the element's identity (type/automationId/name path) is unchanged, so IDs from an earlier snapshot remain clickable. Diff mode returns added in elements, changed in changed, removed (previous IDs) in removed; unchanged elements are not re-sent.",
        };
        return new SnapshotResult
        {
            Window = win,
            Elements = elements,
            Changed = changed,
            Removed = removed,
            IsDiff = isDiff,
            RawCount = rawCount,
            Truncated = truncated,
        };
    }

    private static Dictionary<string, object> DescribeKept(Node n, string id, string parentId, int depth)
    {
        var d = new Dictionary<string, object>
        {
            ["id"] = id,
            ["t"] = n.Type,
            ["r"] = n.Rect.IsEmpty ? Array.Empty<int>() : new[] { (int)n.Rect.X, (int)n.Rect.Y, (int)n.Rect.Width, (int)n.Rect.Height },
        };
        if (parentId.Length > 0) d["p"] = parentId;
        if (depth > 0) d["d"] = depth;
        if (n.Name.Length > 0) d["n"] = n.Name;
        if (n.Aid.Length > 0) d["aid"] = n.Aid;
        if (!n.Enabled) d["en"] = 0;
        if (n.Offscreen) d["off"] = 1;
        if (n.Focused) d["foc"] = 1;
        if (n.Patterns.Count > 0) d["pat"] = n.Patterns;
        if (n.Value.Length > 0) d["val"] = n.Value;
        if (n.Toggle.Length > 0) d["tog"] = n.Toggle;
        if (n.Selected) d["sel"] = 1;
        return d;
    }

    private static T Safe<T>(Func<T> f, T fallback)
    {
        try { return f(); } catch { return fallback; }
    }

    public static AutomationElement GetElement(string id)
    {
        lock (Gate)
        {
            if (_cache.TryGetValue(id, out var el)) return el;
        }
        throw new InvalidOperationException($"unknown element id '{id}' — take a snapshot first (IDs are refreshed by each snapshot)");
    }

    /// <summary>Click an element: prefer semantic patterns, fall back to a
    /// coordinate click at its clickable point / rectangle center.</summary>
    public static Dictionary<string, object> ClickElement(string id, string button, int count)
    {
        var el = GetElement(id);
        string how;
        if (button == "left" && count == 1 && el.TryGetCurrentPattern(InvokePattern.Pattern, out object ip))
        {
            ((InvokePattern)ip).Invoke();
            how = "invoke";
        }
        else if (button == "left" && count == 1 && el.TryGetCurrentPattern(TogglePattern.Pattern, out object tp))
        {
            ((TogglePattern)tp).Toggle();
            how = "toggle";
        }
        else
        {
            (int cx, int cy) = ClickPoint(el);
            DesktopOps.ClickAt(cx, cy, button, count);
            how = "coordinate";
        }
        return new Dictionary<string, object>
        {
            ["element"] = id,
            ["how"] = how,
            ["name"] = Safe(() => el.Current.Name, ""),
            ["type"] = Safe(() => el.Current.ControlType.ProgrammaticName.Replace("ControlType.", ""), "?"),
        };
    }

    public static (int x, int y) ClickPoint(AutomationElement el)
    {
        if (el.TryGetClickablePoint(out System.Windows.Point pt))
            return ((int)pt.X, (int)pt.Y);
        var r = Safe(() => el.Current.BoundingRectangle, System.Windows.Rect.Empty);
        if (r.IsEmpty || r.Width <= 0 || r.Height <= 0)
        {
            if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out object sp))
            {
                ((SelectionItemPattern)sp).Select();
                throw new InvalidOperationException("element has no clickable area; selected it via SelectionItemPattern instead");
            }
            throw new InvalidOperationException("element has no clickable area (offscreen or zero-size)");
        }
        return ((int)(r.X + r.Width / 2), (int)(r.Y + r.Height / 2));
    }

    public static Dictionary<string, object> SetValue(string id, string text)
    {
        var el = GetElement(id);
        if (el.TryGetCurrentPattern(ValuePattern.Pattern, out object vp))
        {
            var v = (ValuePattern)vp;
            if (v.Current.IsReadOnly) throw new InvalidOperationException("element value is read-only");
            v.SetValue(text);
            return new Dictionary<string, object> { ["element"] = id, ["how"] = "value-pattern", ["value"] = text };
        }
        try { el.SetFocus(); } catch { /* some elements refuse focus */ }
        Thread.Sleep(80);
        DesktopOps.TypeText(text);
        return new Dictionary<string, object> { ["element"] = id, ["how"] = "focus+type", ["value"] = text };
    }

    public static Dictionary<string, object> ScrollIntoView(string id)
    {
        var el = GetElement(id);
        if (el.TryGetCurrentPattern(ScrollItemPattern.Pattern, out object sp))
        {
            ((ScrollItemPattern)sp).ScrollIntoView();
            return new Dictionary<string, object> { ["element"] = id, ["how"] = "scroll-item" };
        }
        throw new InvalidOperationException("element does not support ScrollItemPattern");
    }

    public static long CacheHwnd { get { lock (Gate) return _cacheHwnd; } }
}
