// ============================================================
//  CIBuildWindow.cs  -  cua so dieu khien trong Unity Editor
//  Menu:  CI Build > Bang dieu khien
//  File nay do tool sinh ra, dung sua tay.
// ============================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEngine;
using UnityEngine.UIElements;
using Debug = UnityEngine.Debug;

namespace VTL.CI
{
    [Serializable] class CiLink   { public string toolDir; }

    [Serializable] class CiAgentView
    {
        public string name;
        public string state;
        public string jobId;
        public string[] canBuild;
        public string lastSeen;
    }

    [Serializable] class CiProjectEntry
    {
        public string name;
        public string projectPath;
        public string gitRemote;
        public string unityVersion;
        public string worktreePath;
        public string buildsPath;
    }

    [Serializable] class CiConfig
    {
        public int    version;
        public string role;
        public string agentName;
        public string ciRoot;
        public string defaultProject;
        public CiProjectEntry[] projects;

        // config doi cu (mot project, field nam thang o goc) - van doc duoc
        public string projectName;
        public string projectPath;
        public string worktreePath;
        public string buildsPath;
    }

    [Serializable] class CiJobView
    {
        public string id;
        public string project;
        public string branch;
        public string shaShort;
        public string format;
        public string config;
        public bool developmentBuild;
    }

    [Serializable] class CiResultView
    {
        public string id;
        public string project;
        public bool   cancelled;
        public bool   success;
        public string branch;
        public string shaShort;
        public string subject;
        public string format;
        public string config;
        public string outputPath;
        public string errorsPath;
        public string failReason;
        public double durationSec;
        public long sizeBytes;
        public string profile;
        public string cacheState;
        public bool developmentBuild;
    }

    public class CIBuildWindow : EditorWindow
    {
        const string LinkFile = "UserSettings/CIBuildLink.json";

        string          _toolDir;
        CiConfig        _cfg;
        CiProjectEntry  _proj;
        DropdownField _formatField, _configField, _branchField;
        Toggle _developmentField;
        VisualElement _cancelRow;
        Label        _headLabel, _stateLabel;
        HelpBox      _dirtyBox, _errorBox;
        ScrollView   _history;

        // ---------- menu ----------
        [MenuItem("CI Build/Bang dieu khien", false, 0)]
        public static void Open()
        {
            var w = GetWindow<CIBuildWindow>("CI Build");
            w.minSize = new Vector2(380, 420);
            w.Show();
        }

        [MenuItem("CI Build/Build nhanh - APK dev %&b", false, 20)]
        public static void QuickDevApk() { EnqueueFromMenu("apk", "dev"); }

        [MenuItem("CI Build/Build - AAB release", false, 21)]
        public static void QuickReleaseAab() { EnqueueFromMenu("aab", "release"); }

        [MenuItem("CI Build/Mo thu muc file build", false, 40)]
        public static void OpenBuildsFolder()
        {
            var cfg  = LoadConfig(LoadToolDir());
            var proj = ResolveProject(cfg);
            if (proj != null && Directory.Exists(proj.buildsPath)) EditorUtility.RevealInFinder(proj.buildsPath);
            else Debug.LogWarning("[CI] Chua co thu muc build. Chay install.bat truoc.");
        }

        // ---------- UI ----------
        void CreateGUI()
        {
            _toolDir = LoadToolDir();
            _cfg     = LoadConfig(_toolDir);
            _proj    = ResolveProject(_cfg);

            var root = rootVisualElement;
            root.style.paddingLeft = 10; root.style.paddingRight = 10;
            root.style.paddingTop  = 10; root.style.paddingBottom = 10;

            if (_cfg == null || _proj == null)
            {
                root.Add(new HelpBox(
                    "Chua cai dat cho project nay.\nMo thu muc tool va double-click install.bat, roi mo lai cua so nay.",
                    HelpBoxMessageType.Warning));
                return;
            }

            var title = new Label(_proj.name) { style = { unityFontStyleAndWeight = FontStyle.Bold, fontSize = 14 } };
            root.Add(title);

            if (Norm(_proj.projectPath) != Norm(CurrentProjectRoot()))
            {
                root.Add(new HelpBox(
                    "Project dang mo khong khop voi cau hinh nao.\nDang dung tam '" + _proj.name +
                    "'. Chay install.bat de them project nay.",
                    HelpBoxMessageType.Warning));
            }

            _headLabel = new Label { style = { marginBottom = 6, color = new StyleColor(new Color(.6f,.6f,.6f)) } };
            root.Add(_headLabel);

            _dirtyBox = new HelpBox("", HelpBoxMessageType.Info) { style = { display = DisplayStyle.None } };
            root.Add(_dirtyBox);

            _branchField = new DropdownField("Branch", new List<string> { "..." }, 0);
            _branchField.tooltip = "Chon branch khac de build ma KHONG doi working copy dang mo";
            root.Add(_branchField);

            _formatField = new DropdownField("Dinh dang", new List<string> { "APK", "AAB" }, 0);
            _configField = new DropdownField("Ban",       new List<string> { "dev", "release" }, 0);
            root.Add(_formatField);
            root.Add(_configField);
            _developmentField = new Toggle("Development Build") { value = false };
            _developmentField.tooltip = "Opt-in Unity Development Build; khong dong nghia voi Dev signing.";
            root.Add(_developmentField);

            RefreshBranches();

            var buildBtn = new Button(OnBuildClicked) { text = "Build (chay nen)" };
            buildBtn.style.height = 32;
            buildBtn.style.marginTop = 8;
            root.Add(buildBtn);

            _stateLabel = new Label { style = { marginTop = 8, marginBottom = 4 } };
            root.Add(_stateLabel);

            _errorBox = new HelpBox("", HelpBoxMessageType.Error) { style = { display = DisplayStyle.None } };
            root.Add(_errorBox);

            _cancelRow = new VisualElement { style = { flexDirection = FlexDirection.Row, marginTop = 4, display = DisplayStyle.None } };
            root.Add(_cancelRow);

            var row = new VisualElement { style = { flexDirection = FlexDirection.Row, marginTop = 4 } };
            row.Add(new Button(() => EditorUtility.RevealInFinder(_proj.buildsPath)) { text = "Mo thu muc build", style = { flexGrow = 1 } });
            row.Add(new Button(Refresh) { text = "Lam moi", style = { flexGrow = 1 } });
            root.Add(row);

            root.Add(new Label("Ket qua gan day") { style = { unityFontStyleAndWeight = FontStyle.Bold, marginTop = 10 } });
            _history = new ScrollView { style = { flexGrow = 1 } };
            root.Add(_history);

            Refresh();
            root.schedule.Execute(Refresh).Every(3000);
        }

        void OnBuildClicked()
        {
            var git = GetGit();
            if (git == null) { ShowError("Khong doc duoc git tai " + _proj.projectPath); return; }

            // Chon branch khac -> lay dinh cua branch do, khong doi working copy
            var wantBranch = _branchField != null ? _branchField.value : null;
            if (!string.IsNullOrEmpty(wantBranch) && wantBranch != git.Branch)
            {
                Git(_proj.projectPath, "fetch --quiet");
                var tip = ReadGitForBranch(_proj.projectPath, wantBranch);
                if (tip == null) { ShowError("Khong tim thay branch '" + wantBranch + "'"); return; }
                git = tip;
            }

            if (git.Dirty)
            {
                bool go = EditorUtility.DisplayDialog("Co thay doi chua commit",
                    "Build lay dung commit HEAD.\n\nNhung thay doi chua commit SE KHONG co trong ban build nay.\n\nVan build?",
                    "Build tu HEAD", "Huy");
                if (!go) return;
            }

            try
            {
                var target = AskWhereToBuild(_cfg);
                if (target == null) return;                      // nguoi dung huy

                var job = Enqueue(_toolDir, _cfg, _proj, git,
                                  _formatField.value.ToLower(),
                                  _configField.value,
                                  _developmentField != null && _developmentField.value,
                                  "unity-editor", target);

                // Chi tu khoi dong runner khi build tai chinh may nay
                if (!string.IsNullOrEmpty(target)) StartRunner(_toolDir);

                ShowError("");
                _stateLabel.text = string.IsNullOrEmpty(target)
                    ? "Da gui sang may build: " + job
                    : "Da xep hang " + job + " - dang build nen tai may nay...";
                Refresh();
            }
            catch (Exception e) { ShowError(e.Message); }
        }

        // Nap danh sach branch, giu nguyen lua chon hien tai neu con
        void RefreshBranches()
        {
            if (_branchField == null || _proj == null) return;
            var keep = _branchField.value;
            var list = Branches(_proj.projectPath);
            if (list.Count == 0) return;

            _branchField.choices = list;
            if (!string.IsNullOrEmpty(keep) && list.Contains(keep)) _branchField.value = keep;
            else
            {
                var git = ReadGit(_proj.projectPath);
                var cur = git != null ? git.Branch : null;
                _branchField.value = (!string.IsNullOrEmpty(cur) && list.Contains(cur)) ? cur : list[0];
            }
        }

        static List<string> Branches(string repo)
        {
            var list = new List<string>();
            try
            {
                var raw = Git(repo, "for-each-ref --format=%(refname:short) refs/heads refs/remotes");
                foreach (var line in raw.Split('\n'))
                {
                    var n = line.Trim();
                    if (n.Length == 0 || n.EndsWith("/HEAD")) continue;
                    if (n.StartsWith("origin/")) n = n.Substring(7);
                    if (!list.Contains(n)) list.Add(n);
                }
            }
            catch { }
            return list;
        }

        // Dinh cua mot branch, khong dong den working copy
        static GitInfo ReadGitForBranch(string repo, string branch)
        {
            foreach (var r in new[] { branch, "origin/" + branch })
            {
                try
                {
                    var sha = Git(repo, "rev-parse --verify --quiet " + r + "^{commit}");
                    if (string.IsNullOrEmpty(sha) || sha.Length < 7) continue;
                    return new GitInfo
                    {
                        Sha      = sha,
                        ShaShort = sha.Substring(0, 7),
                        Branch   = branch,
                        Subject  = Git(repo, "log -1 --pretty=%s " + sha),
                        Dirty    = false,   // build branch khac -> file chua commit khong lien quan
                        Count    = int.TryParse(Git(repo, "rev-list --count " + sha), out var c) ? c : 0
                    };
                }
                catch { }
            }
            return null;
        }

        void RefreshCancelRow()
        {
            if (_cancelRow == null) return;
            _cancelRow.Clear();

            var jobs = RunningJobs(_cfg, _proj.name);
            if (jobs.Count == 0) { _cancelRow.style.display = DisplayStyle.None; return; }
            _cancelRow.style.display = DisplayStyle.Flex;

            foreach (var j in jobs)
            {
                var job = j;
                var btn = new Button(() =>
                {
                    if (!EditorUtility.DisplayDialog("Huy build",
                            "Dung build " + job.id + " (" + job.branch + "@" + job.shaShort + ")?\n\n" +
                            "Unity tren may build se bi dung ngay.",
                            "Huy build", "Khong")) return;
                    RequestCancel(_cfg, job.id);
                    _stateLabel.text = "Da yeu cau dung " + job.id + "...";
                })
                { text = "Huy " + job.branch + "@" + job.shaShort, style = { flexGrow = 1 } };
                _cancelRow.Add(btn);
            }
        }

        void ShowError(string msg)
        {
            if (_errorBox == null) return;
            _errorBox.text = msg;
            _errorBox.style.display = string.IsNullOrEmpty(msg) ? DisplayStyle.None : DisplayStyle.Flex;
        }

        void Refresh()
        {
            if (_cfg == null || _proj == null || _headLabel == null) return;

            var git = GetGit();
            if (git != null)
            {
                _headLabel.text = git.Branch + " @ " + git.ShaShort + "  -  " + git.Subject;
                if (git.Dirty)
                {
                    _dirtyBox.text = "Dang co file chua commit. Ban build se KHONG gom nhung thay doi do.";
                    _dirtyBox.style.display = DisplayStyle.Flex;
                }
                else _dirtyBox.style.display = DisplayStyle.None;
            }

            int queued = 0;
            var qdir = Path.Combine(_cfg.ciRoot, "queue");
            if (Directory.Exists(qdir)) queued = Directory.GetFiles(qdir, "*.json").Length;

            var pdir = Path.Combine(_cfg.ciRoot, "processing");
            bool running = Directory.Exists(pdir) && Directory.GetFiles(pdir, "*.json").Length > 0;

            _stateLabel.text = running
                ? "DANG BUILD" + (queued > 0 ? "  (+" + queued + " cho)" : "")
                : (queued > 0 ? queued + " job dang cho" : "Ranh");

            RefreshBranches();
            RefreshCancelRow();
            RefreshHistory();
        }

        void RefreshHistory()
        {
            _history.Clear();
            var rdir = Path.Combine(_cfg.ciRoot, "results");
            if (!Directory.Exists(rdir)) return;

            var files = Directory.GetFiles(rdir, "*.json")
                                 .OrderByDescending(f => f)
                                 .Take(40);

            foreach (var f in files)
            {
                CiResultView r;
                try { r = JsonUtility.FromJson<CiResultView>(File.ReadAllText(f)); }
                catch { continue; }
                if (r == null) continue;
                // queue dung chung cho moi project -> chi hien build cua project dang mo
                if (!string.IsNullOrEmpty(r.project) && r.project != _proj.name) continue;

                var row = new VisualElement
                {
                    style = { flexDirection = FlexDirection.Row, marginBottom = 2, alignItems = Align.Center }
                };

                var dot = new Label(r.success ? "OK" : (r.cancelled ? "-" : "X"))
                {
                    style = { width = 22, unityFontStyleAndWeight = FontStyle.Bold,
                              color = new StyleColor(r.success ? new Color(.3f,.8f,.4f)
                                                   : (r.cancelled ? new Color(.55f,.55f,.55f) : new Color(.9f,.35f,.35f))) }
                };
                row.Add(dot);

                var profile = string.IsNullOrEmpty(r.profile)
                    ? (r.format ?? "").ToUpper() + "/" + r.config + "/quick" : r.profile;
                var text = r.branch + "@" + r.shaShort + "  " + profile +
                           "  " + Mathf.RoundToInt((float)r.durationSec) + "s" +
                           (r.sizeBytes > 0 ? "  " + (r.sizeBytes / (1024f * 1024f)).ToString("0.0") + " MB" : "") +
                           (!string.IsNullOrEmpty(r.cacheState) ? "  cache:" + r.cacheState : "");
                row.Add(new Label(text) { style = { flexGrow = 1 } });

                if (r.success && !string.IsNullOrEmpty(r.outputPath))
                    row.Add(new Button(() => EditorUtility.RevealInFinder(r.outputPath)) { text = "..." });
                else if (!string.IsNullOrEmpty(r.errorsPath) && File.Exists(r.errorsPath))
                    row.Add(new Button(() => Process.Start(new ProcessStartInfo(r.errorsPath) { UseShellExecute = true })) { text = "loi" });

                _history.Add(row);
            }
        }

        // ---------- dung chung ----------
        class GitInfo { public string Sha, ShaShort, Branch, Subject; public bool Dirty; public int Count; }

        GitInfo GetGit() { return ReadGit(_proj.projectPath); }

        static GitInfo ReadGit(string repo)
        {
            try
            {
                var sha = Git(repo, "rev-parse HEAD");
                if (string.IsNullOrEmpty(sha)) return null;
                return new GitInfo
                {
                    Sha      = sha,
                    ShaShort = sha.Substring(0, 7),
                    Branch   = Git(repo, "rev-parse --abbrev-ref HEAD"),
                    Subject  = Git(repo, "log -1 --pretty=%s"),
                    Dirty    = !string.IsNullOrEmpty(Git(repo, "status --porcelain")),
                    Count    = int.TryParse(Git(repo, "rev-list --count HEAD"), out var c) ? c : 0
                };
            }
            catch { return null; }
        }

        static string Git(string repo, string args)
        {
            var psi = new ProcessStartInfo("git", "-C \"" + repo + "\" " + args)
            {
                UseShellExecute        = false,
                RedirectStandardOutput = true,
                RedirectStandardError  = true,
                CreateNoWindow         = true
            };
            using (var p = Process.Start(psi))
            {
                var o = p.StandardOutput.ReadToEnd();
                p.WaitForExit(10000);
                return o.Trim();
            }
        }

        // Thu muc goc cua project Unity dang mo (Application.dataPath tro vao Assets)
        static string CurrentProjectRoot()
        {
            try { return Directory.GetParent(Application.dataPath).FullName; }
            catch { return ""; }
        }

        static string Norm(string p)
        {
            if (string.IsNullOrEmpty(p)) return "";
            return p.Replace('/', '\\').TrimEnd('\\').ToLowerInvariant();
        }

        // Tu nhan dung project: doi chieu duong dan project dang mo voi danh sach
        // trong config. Nho vay mo project nao thi build project do, khong phai chon.
        static CiProjectEntry ResolveProject(CiConfig cfg)
        {
            if (cfg == null) return null;

            var list = cfg.projects;
            if (list == null || list.Length == 0)
            {
                // config doi cu - dung cac field o goc
                if (string.IsNullOrEmpty(cfg.projectPath)) return null;
                return new CiProjectEntry {
                    name = cfg.projectName, projectPath = cfg.projectPath,
                    worktreePath = cfg.worktreePath, buildsPath = cfg.buildsPath
                };
            }

            var here = Norm(CurrentProjectRoot());
            foreach (var p in list)
                if (Norm(p.projectPath) == here) return p;

            foreach (var p in list)
                if (p.name == cfg.defaultProject) return p;

            return list[0];
        }

        static bool IsAgentRole(CiConfig cfg)
        {
            var r = cfg != null ? cfg.role : null;
            return string.IsNullOrEmpty(r) || r == "agent" || r == "standalone";
        }

        // Doc nhip tim cac agent tren o chung. Im qua 60 giay thi coi nhu chet.
        static List<CiAgentView> LiveAgents(CiConfig cfg, string platform)
        {
            var list = new List<CiAgentView>();
            try
            {
                var dir = Path.Combine(cfg.ciRoot, "agents");
                if (!Directory.Exists(dir)) return list;
                foreach (var f in Directory.GetFiles(dir, "*.json"))
                {
                    CiAgentView a;
                    try { a = JsonUtility.FromJson<CiAgentView>(File.ReadAllText(f)); } catch { continue; }
                    if (a == null) continue;
                    DateTime seen;
                    if (!DateTime.TryParse(a.lastSeen, out seen)) continue;
                    if ((DateTime.Now - seen).TotalSeconds >= 60) continue;
                    if (a.canBuild != null && Array.IndexOf(a.canBuild, platform) < 0) continue;
                    list.Add(a);
                }
            }
            catch { }
            return list;
        }

        // Tra ve: "" = gui sang may build, "<ten may>" = build tai may nay, null = huy
        static string AskWhereToBuild(CiConfig cfg)
        {
            if (IsAgentRole(cfg)) return cfg.agentName;          // standalone: build tai cho
            if (LiveAgents(cfg, "android").Count > 0) return "";  // co may build

            int c = EditorUtility.DisplayDialogComplex(
                "Khong thay may build",
                "Khong co may build nao dang chay.\n\n" +
                "De trong queue: may build bat len la tu chay.\n\n" +
                "Build tai may nay: Editor van dung duoc, nhung may se an gan het CPU. " +
                "Lan dau con phai tai ve va import lai toan bo asset (20-40 phut).",
                "De trong queue", "Huy", "Build tai may nay");

            if (c == 0) return "";              // queue
            if (c == 2) return cfg.agentName;   // tai cho
            return null;                        // huy
        }

        // Huy build: khong giet tien trinh tu xa duoc (co the dang chay o may khac),
        // nen dat mot file co - runner nhat o vong poll 3 giay san co cua no.
        static void RequestCancel(CiConfig cfg, string jobId)
        {
            try
            {
                var dir = Path.Combine(cfg.ciRoot, "cancel");
                Directory.CreateDirectory(dir);
                File.WriteAllText(Path.Combine(dir, jobId + ".flag"), DateTime.Now.ToString("o"));
            }
            catch (Exception e) { Debug.LogError("[CI] Khong huy duoc: " + e.Message); }
        }

        // Job dang chay = file nam trong processing/<agent>/
        static List<CiJobView> RunningJobs(CiConfig cfg, string projectName)
        {
            var list = new List<CiJobView>();
            try
            {
                var dir = Path.Combine(cfg.ciRoot, "processing");
                if (!Directory.Exists(dir)) return list;
                foreach (var f in Directory.GetFiles(dir, "*.json", SearchOption.AllDirectories))
                {
                    CiJobView j;
                    try { j = JsonUtility.FromJson<CiJobView>(File.ReadAllText(f)); } catch { continue; }
                    if (j == null || string.IsNullOrEmpty(j.id)) continue;
                    if (!string.IsNullOrEmpty(projectName) && j.project != projectName) continue;
                    list.Add(j);
                }
            }
            catch { }
            return list;
        }

        static string LoadToolDir()
        {
            try
            {
                if (!File.Exists(LinkFile)) return null;
                var link = JsonUtility.FromJson<CiLink>(File.ReadAllText(LinkFile));
                return link != null ? link.toolDir : null;
            }
            catch { return null; }
        }

        static CiConfig LoadConfig(string toolDir)
        {
            try
            {
                if (string.IsNullOrEmpty(toolDir)) return null;
                var f = Path.Combine(toolDir, "config.json");
                if (!File.Exists(f)) return null;
                return JsonUtility.FromJson<CiConfig>(File.ReadAllText(f));
            }
            catch { return null; }
        }

        static void EnqueueFromMenu(string format, string config)
        {
            var toolDir = LoadToolDir();
            var cfg     = LoadConfig(toolDir);
            var proj    = ResolveProject(cfg);
            if (cfg == null || proj == null) { Debug.LogError("[CI] Chua cai dat - chay install.bat truoc."); return; }

            var git = ReadGit(proj.projectPath);
            if (git == null) { Debug.LogError("[CI] Khong doc duoc git."); return; }

            if (git.Dirty && !EditorUtility.DisplayDialog("Co thay doi chua commit",
                    "Build lay dung commit HEAD, nhung thay doi chua commit se khong co trong ban build.\n\nVan build?",
                    "Build tu HEAD", "Huy")) return;

            var target = AskWhereToBuild(cfg);
            if (target == null) return;

            var id = Enqueue(toolDir, cfg, proj, git, format, config, false, "unity-menu", target);
            if (!string.IsNullOrEmpty(target)) StartRunner(toolDir);

            Debug.Log("[CI] Da xep hang " + id + " [" + proj.name + "]" +
                      (string.IsNullOrEmpty(target) ? " - da gui sang may build." : " - dang build nen tai may nay."));
        }

        static string Enqueue(string toolDir, CiConfig cfg, CiProjectEntry proj, GitInfo git, string format, string config, bool developmentBuild, string by, string targetAgent)
        {
            var id = DateTime.Now.ToString("yyyyMMdd-HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 4);
            var job = new CiJob
            {
                id          = id,
                project     = proj.name,
                platform    = "android",
                targetAgent = targetAgent ?? "",
                gitRemote   = proj.gitRemote ?? "",
                unityVersion= proj.unityVersion ?? "",
                sha         = git.Sha,
                shaShort    = git.ShaShort,
                branch      = git.Branch,
                subject     = git.Subject,
                format      = format,
                config      = config,
                developmentBuild = developmentBuild,
                by          = by,
                versionCode = git.Count,
                versionName = "",
                outputPath  = "",
                resultPath  = "",
                createdAt   = DateTime.Now.ToString("o")
            };

            var qdir = Path.Combine(cfg.ciRoot, "queue");
            Directory.CreateDirectory(qdir);
            var tmp = Path.Combine(qdir, id + ".json.tmp");
            var fin = Path.Combine(qdir, id + ".json");
            File.WriteAllText(tmp, JsonUtility.ToJson(job, true));
            if (File.Exists(fin)) File.Delete(fin);
            File.Move(tmp, fin);      // rename = atomic, runner khong doc phai file dang ghi do
            return id;
        }

        static void StartRunner(string toolDir)
        {
            var runner = Path.Combine(toolDir, "runner.ps1");
            if (!File.Exists(runner)) { Debug.LogError("[CI] Khong tim thay runner.ps1"); return; }
            var psi = new ProcessStartInfo("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + runner + "\"")
            {
                UseShellExecute = false,
                CreateNoWindow  = true
            };
            Process.Start(psi);
        }
    }
}
