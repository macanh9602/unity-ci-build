// ============================================================
//  CIBuild.cs  -  diem vao khi build o che do batchmode
//  Runner goi: Unity.exe -batchmode -executeMethod VTL.CI.CIBuild.Run -ciJob <file>
//  File nay do tool sinh ra, dung sua tay.
// ============================================================
using System;
using System.IO;
using System.Linq;
using UnityEditor;
using UnityEditor.Build.Reporting;
using UnityEngine;

namespace VTL.CI
{
    [Serializable]
    public class CiJob
    {
        public string id;
        public string project;
        public string platform;
        public string targetAgent;
        public string gitRemote;
        public string unityVersion;
        public string sha;
        public string shaShort;
        public string branch;
        public string subject;
        public string format;      // apk | aab
        public string config;      // dev | release
        public string by;
        public int    versionCode;
        public string versionName;
        public string outputPath;
        public string resultPath;
        public string createdAt;
    }

    [Serializable]
    public class CiUnityResult
    {
        public string id;
        public bool   success;
        public string result;
        public string outputPath;
        public long   sizeBytes;
        public double durationSeconds;
        public int    totalErrors;
        public int    totalWarnings;
        public string message;
    }

    public static class CIBuild
    {
        const string LOG = "[CI] ";

        public static void Run()
        {
            var started  = DateTime.UtcNow;
            int exitCode = 1;
            CiJob job    = null;

            try
            {
                job = ReadJob();
                Debug.Log(LOG + "job " + job.id + "  [" + job.project + "]  " + job.format + "/" + job.config +
                          "  versionCode=" + job.versionCode);

                EnsureAndroidTarget();
                ApplySettings(job);

                var scenes = EditorBuildSettings.scenes
                    .Where(s => s.enabled && !string.IsNullOrEmpty(s.path))
                    .Select(s => s.path)
                    .ToArray();

                if (scenes.Length == 0)
                    throw new Exception("Khong co scene nao duoc bat trong Build Settings.");

                var dir = Path.GetDirectoryName(job.outputPath);
                if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
                if (File.Exists(job.outputPath)) File.Delete(job.outputPath);

                var opts = new BuildPlayerOptions
                {
                    scenes           = scenes,
                    locationPathName = job.outputPath,
                    target           = BuildTarget.Android,
                    targetGroup      = BuildTargetGroup.Android,
                    options          = job.config == "dev"
                                       ? BuildOptions.Development
                                       : BuildOptions.None
                };

                Debug.Log(LOG + "build -> " + job.outputPath + "  (" + scenes.Length + " scene)");
                var report  = BuildPipeline.BuildPlayer(opts);
                var summary = report.summary;
                bool ok     = summary.result == BuildResult.Succeeded;

                WriteResult(job, new CiUnityResult
                {
                    id              = job.id,
                    success         = ok,
                    result          = summary.result.ToString(),
                    outputPath      = ok ? job.outputPath : "",
                    sizeBytes       = ok && File.Exists(job.outputPath) ? new FileInfo(job.outputPath).Length : 0,
                    durationSeconds = (DateTime.UtcNow - started).TotalSeconds,
                    totalErrors     = (int)summary.totalErrors,
                    totalWarnings   = (int)summary.totalWarnings,
                    message         = ok ? "" : ("BuildResult=" + summary.result)
                });

                Debug.Log(LOG + (ok ? "THANH CONG" : "THAT BAI") + "  errors=" + summary.totalErrors);
                exitCode = ok ? 0 : 1;
            }
            catch (Exception e)
            {
                Debug.LogError(LOG + "Exception: " + e);
                try
                {
                    WriteResult(job, new CiUnityResult
                    {
                        id              = job != null ? job.id : "unknown",
                        success         = false,
                        result          = "Exception",
                        durationSeconds = (DateTime.UtcNow - started).TotalSeconds,
                        message         = e.Message
                    });
                }
                catch { }
                exitCode = 1;
            }
            finally
            {
                // Bat buoc tu goi Exit: neu dung -quit thi Unity luon tra ma 0,
                // runner se tuong build thanh cong du that bai.
                EditorApplication.Exit(exitCode);
            }
        }

        static CiJob ReadJob()
        {
            string path = null;
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == "-ciJob") { path = args[i + 1]; break; }

            if (string.IsNullOrEmpty(path)) throw new Exception("Thieu tham so -ciJob");
            if (!File.Exists(path))         throw new Exception("Khong tim thay file job: " + path);

            var job = JsonUtility.FromJson<CiJob>(File.ReadAllText(path));
            if (job == null || string.IsNullOrEmpty(job.outputPath))
                throw new Exception("File job khong hop le: " + path);
            return job;
        }

        static void EnsureAndroidTarget()
        {
            if (EditorUserBuildSettings.activeBuildTarget != BuildTarget.Android)
            {
                Debug.Log(LOG + "doi platform sang Android...");
                EditorUserBuildSettings.SwitchActiveBuildTarget(BuildTargetGroup.Android, BuildTarget.Android);
            }
        }

        static void ApplySettings(CiJob job)
        {
            EditorUserBuildSettings.buildAppBundle = (job.format == "aab");
            EditorUserBuildSettings.development    = (job.config == "dev");

            if (job.versionCode > 0) PlayerSettings.Android.bundleVersionCode = job.versionCode;
            if (!string.IsNullOrEmpty(job.versionName)) PlayerSettings.bundleVersion = job.versionName;

            if (job.config == "release") ApplyKeystoreFromEnvironment();
            else PlayerSettings.Android.useCustomKeystore = false;   // ban dev ky bang debug keystore
        }

        // Mat khau di qua bien moi truong, khong bao gio ghi ra dia.
        static void ApplyKeystoreFromEnvironment()
        {
            var ksPath = Environment.GetEnvironmentVariable("CI_KEYSTORE_PATH");
            var ksPass = Environment.GetEnvironmentVariable("CI_KEYSTORE_PASS");
            var kaName = Environment.GetEnvironmentVariable("CI_KEYALIAS_NAME");
            var kaPass = Environment.GetEnvironmentVariable("CI_KEYALIAS_PASS");

            if (string.IsNullOrEmpty(ksPath) || !File.Exists(ksPath))
            {
                Debug.LogWarning(LOG + "Ban release nhung khong co keystore - se ky bang debug keystore.");
                PlayerSettings.Android.useCustomKeystore = false;
                return;
            }

            PlayerSettings.Android.useCustomKeystore = true;
            PlayerSettings.Android.keystoreName = ksPath;
            PlayerSettings.Android.keystorePass = ksPass ?? "";
            PlayerSettings.Android.keyaliasName = kaName ?? "";
            PlayerSettings.Android.keyaliasPass = kaPass ?? "";
            Debug.Log(LOG + "da nap keystore: " + Path.GetFileName(ksPath));
        }

        static void WriteResult(CiJob job, CiUnityResult result)
        {
            if (job == null || string.IsNullOrEmpty(job.resultPath)) return;
            var dir = Path.GetDirectoryName(job.resultPath);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);
            File.WriteAllText(job.resultPath, JsonUtility.ToJson(result, true));
        }
    }
}
