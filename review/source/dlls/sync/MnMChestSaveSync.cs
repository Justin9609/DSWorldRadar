using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

namespace MnMChestSaveSync
{
    internal static class Program
    {
        private const string Version = "2.8.0-DSWR1.0.4-single-writer";

        private const string GameExeName = "DSClient-Win64-Shipping.exe";

        private static readonly byte[] SqlCipherPass = Encoding.ASCII.GetBytes("13314374259236352028");

        private static int Main(string[] args)
        {
            try { Console.OutputEncoding = Encoding.UTF8; Console.Title = "DSWorldRadar 宝箱存档同步器"; } catch { }
            try
            {
                if (HasFlag(args, "--help"))
                {
                    Console.WriteLine("DSWorldRadar " + Version);
                    Console.WriteLine("--fast-seed | --fast-live | --progress-only [--save-reload] [--in-game] [--game-root PATH]");
                    return 0;
                }
                ValidateArguments(args);
                bool inGame = HasFlag(args, "--in-game");
                bool progressOnly = HasFlag(args, "--progress-only");
                bool fastLive = HasFlag(args, "--fast-live");
                bool saveReload = HasFlag(args, "--save-reload");
                string toolRoot = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar);
                string gameRoot = ResolveGameRoot(GetOption(args, "--game-root"), toolRoot);
                Paths paths = new Paths(gameRoot, toolRoot);
                paths.Validate(false);
                if (!inGame && Process.GetProcessesByName("DSClient-Win64-Shipping").Length > 0)
                    throw new InvalidOperationException("请先完全退出游戏，或由 MOD 使用 --in-game 自动同步。");
                using (SyncWriteLease lease = new SyncWriteLease(toolRoot))
                {
                    WriteHeader(gameRoot, paths);
                    if (progressOnly) return FastProgressOnly(paths);
                    return FastLiveSynchronize(paths, !fastLive, saveReload);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("同步失败：" + ex.Message);
                WriteEmergencyLog(ex);
                return 1;
            }
        }

        private static void ValidateArguments(string[] args)
        {
            HashSet<string> flags = new HashSet<string>(new string[] {
                "--in-game", "--fast-seed", "--fast-live", "--save-reload", "--progress-only"
            }, StringComparer.OrdinalIgnoreCase);
            for (int i = 0; i < args.Length; i++)
            {
                if (String.Equals(args[i], "--game-root", StringComparison.OrdinalIgnoreCase))
                {
                    if (++i >= args.Length || args[i].StartsWith("--", StringComparison.Ordinal))
                        throw new ArgumentException("--game-root 需要游戏目录。");
                }
                else if (!args[i].StartsWith("--game-root=", StringComparison.OrdinalIgnoreCase) && !flags.Contains(args[i]))
                    throw new ArgumentException("不支持的参数：" + args[i] + "。请使用 --help 查看当前参数。");
            }
            int modes = (HasFlag(args, "--fast-seed") ? 1 : 0) + (HasFlag(args, "--fast-live") ? 1 : 0) + (HasFlag(args, "--progress-only") ? 1 : 0);
            if (modes > 1) throw new ArgumentException("同步模式不能同时指定多个。");
        }

        private sealed class SyncWriteLease : IDisposable
        {
            private System.Threading.Mutex gate;
            private bool owned;
            public SyncWriteLease(string toolRoot)
            {
                string key;
                using (SHA256 hash = SHA256.Create())
                    key = BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Path.GetFullPath(toolRoot).ToLowerInvariant()))).Replace("-", "").Substring(0, 24);
                gate = new System.Threading.Mutex(false, "Local\\DSWorldRadar_SaveSync_" + key);
                try
                {
                    try { owned = gate.WaitOne(20000); }
                    catch (System.Threading.AbandonedMutexException) { owned = true; }
                    if (!owned) throw new IOException("另一个同步器仍在写入，请稍后重试。");
                }
                catch { gate.Dispose(); gate = null; throw; }
            }
            public void Dispose()
            {
                if (gate == null) return;
                try { if (owned) gate.ReleaseMutex(); }
                finally { gate.Dispose(); gate = null; owned = false; }
            }
        }

        private static void WriteHeader(string gameRoot, Paths paths)
        {
            Console.WriteLine("============================================================");
            Console.WriteLine(" DSWorldRadar 宝箱存档同步器 v" + Version);
            Console.WriteLine("============================================================");
            Console.WriteLine("游戏目录：" + gameRoot);
            Console.WriteLine("雷达节点：" + paths.MnmNodesPath);
            Console.WriteLine("雷达完整目录：" + paths.MnmCatalogPath);
            Console.WriteLine("雷达进度：" + paths.ProgressPath);
            Console.WriteLine();
        }

        private static int FastLiveSynchronize(Paths paths, bool seedOnly, bool saveReload)
        {
            Stopwatch timer = Stopwatch.StartNew();
            Directory.CreateDirectory(paths.CacheRoot);

            // Current fast path uses the packaged immutable direct catalog: every reconciled chest
            // node is named DSC_<SaveID>. This removes the live dependency on PAK scans
            // and on the old coordinate-derived chest_mapping.csv cache.
            List<MapEntry> mapping = LoadDirectChestMapping(paths.MnmCatalogPath);
            if (mapping.Count < 1500)
            {
                Console.WriteLine("FAST_DIRECT_CATALOG_INVALID=" + mapping.Count.ToString(CultureInfo.InvariantCulture));
                throw new InvalidDataException("快速核销的 DSC_<SaveID> 直接宝箱目录不完整。");
            }

            SaveSelection save = FindFastLiveSave(paths);
            HashSet<long> openedSaveIds = null;
            HashSet<long> dynamicCompletedQuestIds = null;
            int sourceCount = 0;

            // v1.18.34 cold-start safety: the active .db is authoritative.
            // A stale .bak must never be unioned into current completion state. It is used
            // only as a fallback when the primary .db cannot be decrypted/read.
            List<string> candidates = new List<string>();
            candidates.Add(save.Path);
            if (save.RelatedPaths != null)
            {
                foreach (string p in save.RelatedPaths)
                    if (!String.Equals(p, save.Path, StringComparison.OrdinalIgnoreCase))
                        candidates.Add(p);
            }

            Exception primaryFailure = null;
            foreach (string candidate in candidates)
            {
                if (!File.Exists(candidate)) continue;
                bool isPrimary = String.Equals(candidate, save.Path, StringComparison.OrdinalIgnoreCase);
                DateTime writeTime = File.GetLastWriteTimeUtc(candidate);
                if (!isPrimary && Math.Abs((save.WriteTime - writeTime).TotalDays) > 14.0) continue;

                string tempDb = Path.Combine(paths.CacheRoot, "fast_plain_" + Guid.NewGuid().ToString("N") + ".db");
                try
                {
                    DecryptSqlCipher(candidate, tempDb);
                    HashSet<long> chestOne = WinSqlite.ReadOpenedIds(tempDb);
                    HashSet<long> questOne = WinSqlite.ReadCompletedQuestIds(tempDb);

                    openedSaveIds = chestOne;
                    dynamicCompletedQuestIds = questOne;
                    sourceCount = 1;

                    Console.WriteLine(
                        "FAST_AUTHORITY=" +
                        (isPrimary && String.Equals(Path.GetExtension(candidate), ".db", StringComparison.OrdinalIgnoreCase) ? "PRIMARY_DB" : "BACKUP_FALLBACK") +
                        "|" + Path.GetFileName(candidate) +
                        "|opened=" + chestOne.Count.ToString(CultureInfo.InvariantCulture) +
                        "|quests=" + questOne.Count.ToString(CultureInfo.InvariantCulture));
                    break;
                }
                catch (Exception ex)
                {
                    if (isPrimary)
                    {
                        primaryFailure = ex;
                        Console.WriteLine("FAST_PRIMARY_READ_FAILED=" + Path.GetFileName(candidate) + "|" + ex.GetType().Name);
                        if (String.Equals(Path.GetExtension(candidate), ".db", StringComparison.OrdinalIgnoreCase) && File.Exists(candidate))
                            throw new IOException("当前主存档暂不可读；保留现有雷达状态，等待重试。", ex);
                    }
                    else
                    {
                        Console.WriteLine("FAST_FALLBACK_SKIP=" + Path.GetFileName(candidate) + "|" + ex.GetType().Name);
                    }
                }
                finally
                {
                    TryDelete(tempDb);
                }
            }

            if (sourceCount == 0 || openedSaveIds == null || dynamicCompletedQuestIds == null)
                throw new InvalidOperationException(
                    "快速核销未读取到可用的活动 Slot 主 .db 或同 Slot .bak 回退。",
                    primaryFailure);

            HashSet<string> currentChestNodes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (MapEntry entry in mapping)
                if (openedSaveIds.Contains(entry.SaveId)) currentChestNodes.Add(entry.NodeId);

            HashSet<string> areaQuestNodes = LoadNodeIdsByKind(paths, "area_quests");
            HashSet<string> currentAreaNodes = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string id in areaQuestNodes)
            {
                long qid;
                if (Int64.TryParse(id, NumberStyles.Integer, CultureInfo.InvariantCulture, out qid)
                    && dynamicCompletedQuestIds.Contains(qid))
                    currentAreaNodes.Add(id);
            }

            string slotPath = Path.Combine(paths.CacheRoot, "fast_live_slot.txt");
            string chestSnapshotPath = Path.Combine(paths.CacheRoot, "fast_live_chest_snapshot.txt");
            string areaSnapshotPath = Path.Combine(paths.CacheRoot, "fast_live_area_snapshot.txt");
            string activeSlot = Path.GetFullPath(Path.ChangeExtension(save.Path, ".db")).ToLowerInvariant();
            string previousSlot = File.Exists(slotPath) ? File.ReadAllText(slotPath).Trim().ToLowerInvariant() : String.Empty;
            HashSet<string> previousChest = ReadFastSet(chestSnapshotPath);
            HashSet<string> previousArea = ReadFastSet(areaSnapshotPath);

            // A different save path or a strict state shrink means this is not an ordinary
            // completion delta. Re-seed chest + area-quest state directly rather than
            // contaminating a new/rolled-back save with monotonic live additions.
            bool boundary = !seedOnly && previousSlot.Length > 0 && !String.Equals(previousSlot, activeSlot, StringComparison.OrdinalIgnoreCase);
            if (!boundary && !seedOnly && previousSlot.Length > 0)
            {
                if (!currentChestNodes.IsSupersetOf(previousChest) || !currentAreaNodes.IsSupersetOf(previousArea))
                    boundary = true;
            }
            if (boundary)
            {
                Console.WriteLine("FAST_BOUNDARY_FULLSTATE=1");
                seedOnly = true;
            }

            List<string> existingLines = File.Exists(paths.ProgressPath)
                ? File.ReadAllLines(paths.ProgressPath).Select(x => x.Trim()).Where(x => x.Length > 0).ToList()
                : new List<string>();
            HashSet<string> existing = new HashSet<string>(existingLines, StringComparer.OrdinalIgnoreCase);
            int added = 0;
            int restored = 0;
            int transientCompletionReset = 0;

            // v1.18.13: a map/save reload starts a new completion-state generation.  The old
            // progress.txt entries for fly/mole/wave/platform/slider are runtime-derived and
            // cannot be treated as monotonic across saves.  Remove only those 161 known IDs;
            // chest + area-quest entries remain save-authoritative below, and unrelated/manual
            // progress records are preserved.  The native radar will re-query the current save
            // and repopulate the genuinely completed runtime classes.
            if (saveReload || boundary)
            {
                transientCompletionReset = PurgeTransientCompletionProgress(paths, ref existingLines, existing);
                Console.WriteLine("FAST_RELOAD_COMPLETION_RESET=" + transientCompletionReset.ToString(CultureInfo.InvariantCulture));
            }

            if (seedOnly)
            {
                // Startup/save-boundary full-state reconciliation is exact and scoped:
                // only DSC_* chest nodes and area_quests are allowed to be removed.
                HashSet<string> allChestNodes = new HashSet<string>(mapping.Select(x => x.NodeId), StringComparer.OrdinalIgnoreCase);
                List<string> kept = new List<string>();
                foreach (string line in existingLines)
                {
                    bool staleChest = allChestNodes.Contains(line) && !currentChestNodes.Contains(line);
                    bool staleArea = areaQuestNodes.Contains(line) && !currentAreaNodes.Contains(line);
                    if (staleChest || staleArea)
                    {
                        existing.Remove(line);
                        restored++;
                    }
                    else
                    {
                        kept.Add(line);
                    }
                }
                existingLines = kept;
            }

            foreach (string id in currentChestNodes.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                if (existing.Add(id)) { existingLines.Add(id); added++; }
            foreach (string id in currentAreaNodes.OrderBy(x => x, StringComparer.OrdinalIgnoreCase))
                if (existing.Add(id)) { existingLines.Add(id); added++; }

            if (added > 0 || restored > 0 || transientCompletionReset > 0)
                AtomicWriteAllLines(paths.ProgressPath, existingLines);

            Dictionary<string, ChestCount> chestCounts = BuildChestCounts(mapping, openedSaveIds);
            UpdateChestCountLabels(paths, chestCounts);
            WriteChestCountSummary(paths, chestCounts);
            UpdateCompletionCountLabels(paths, existingLines);
            WriteCompletionCountSummary(paths, existingLines);

            Console.WriteLine("RUNTIME_CHEST_ROWS=" + mapping.Count.ToString(CultureInfo.InvariantCulture));

            List<string> chestDelta = new List<string>();
            List<string> areaDelta = new List<string>();
            if (!seedOnly && previousSlot.Length > 0)
            {
                chestDelta = currentChestNodes.Except(previousChest, StringComparer.OrdinalIgnoreCase)
                    .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
                areaDelta = currentAreaNodes.Except(previousArea, StringComparer.OrdinalIgnoreCase)
                    .OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList();
            }

            WriteFastSnapshots(slotPath, chestSnapshotPath, areaSnapshotPath, activeSlot, currentChestNodes, currentAreaNodes);
            WriteAuthoritySnapshot(paths, activeSlot, currentChestNodes, currentAreaNodes);


            Console.WriteLine("FAST_MODE=" + (seedOnly ? "seed" : "live"));
            Console.WriteLine("FAST_SAVE_SOURCES=" + sourceCount.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("FAST_OPENED_BITS=" + openedSaveIds.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("FAST_COMPLETED_QUESTS=" + dynamicCompletedQuestIds.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("FAST_AREA_QUEST_SOURCE=tb_completed_quest+tb_quest_complete+tb_dynamic_quest_complete");
            Console.WriteLine("LIVE_ADDED_IDS=" + String.Join(",", chestDelta.ToArray()));
            Console.WriteLine("LIVE_AREA_QUEST_ADDED_IDS=" + String.Join(",", areaDelta.ToArray()));
            Console.WriteLine("LIVE_AREA_QUEST_COUNT=" + currentAreaNodes.Count.ToString(CultureInfo.InvariantCulture) + "/" + areaQuestNodes.Count.ToString(CultureInfo.InvariantCulture));
            Console.WriteLine("FAST_LIVE_MS=" + timer.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture));
            return 0;
        }

        private static int FastProgressOnly(Paths paths)
        {
            Stopwatch timer = Stopwatch.StartNew();
            List<string> lines = File.Exists(paths.ProgressPath)
                ? File.ReadAllLines(paths.ProgressPath).Select(x => x.Trim()).Where(x => x.Length > 0).ToList()
                : new List<string>();
            UpdateCompletionCountLabels(paths, lines);
            WriteCompletionCountSummary(paths, lines);
            Console.WriteLine("FAST_PROGRESS_ONLY=1");
            Console.WriteLine("FAST_LIVE_MS=" + timer.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture));
            return 0;
        }

        private static List<MapEntry> LoadDirectChestMapping(string mnmNodesPath)
        {
            List<MapEntry> result = new List<MapEntry>();
            HashSet<long> saveIds = new HashSet<long>();
            HashSet<string> nodeIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(mnmNodesPath)) return result;

            bool first = true;
            foreach (string raw in File.ReadLines(mnmNodesPath, Encoding.UTF8))
            {
                if (first) { first = false; continue; }
                if (String.IsNullOrWhiteSpace(raw)) continue;
                string[] p = raw.Split(',');
                if (p.Length < 2) continue;
                string id = p[0].Trim().TrimStart('\uFEFF');
                string kind = p[1].Trim();
                if (!kind.StartsWith("chests_", StringComparison.OrdinalIgnoreCase)) continue;
                if (!id.StartsWith("DSC_", StringComparison.OrdinalIgnoreCase)) continue;
                long saveId;
                if (!Int64.TryParse(id.Substring(4), NumberStyles.Integer, CultureInfo.InvariantCulture, out saveId)) continue;
                if (IsOfficialChestExcluded(saveId)) continue;
                if (!saveIds.Add(saveId) || !nodeIds.Add(id))
                    throw new InvalidDataException("DSC_<SaveID> 直接宝箱目录存在重复项：" + id);
                MapEntry e = new MapEntry();
                e.SaveId = saveId;
                e.NodeId = id;
                e.Distance = 0.0;
                e.Stage = "direct_dsc";
                e.Category = kind;
                result.Add(e);
            }
            return result;
        }

        private static HashSet<string> ReadFastSet(string path)
        {
            HashSet<string> result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!File.Exists(path)) return result;
            foreach (string raw in File.ReadAllLines(path))
            {
                string t = raw.Trim();
                if (t.Length > 0) result.Add(t);
            }
            return result;
        }

        private static void WriteAuthoritySnapshot(Paths paths, string slot, HashSet<string> chests, HashSet<string> areas)
        {
            AtomicWriteAllLines(Path.Combine(paths.CacheRoot, "authority_state.v1.txt"), new string[] {
                "DSWR_STATE_V1",
                "revision=" + Guid.NewGuid().ToString("N"),
                "catalog_sha256=" + Sha256File(paths.MnmCatalogPath),
                "slot_b64=" + Convert.ToBase64String(Encoding.UTF8.GetBytes(slot)),
                "chests=" + String.Join(",", chests.OrderBy(x => x, StringComparer.Ordinal).ToArray()),
                "areas=" + String.Join(",", areas.OrderBy(x => x, StringComparer.Ordinal).ToArray())
            });
        }

        private static void WriteFastSnapshots(
            string slotPath,
            string chestPath,
            string areaPath,
            string activeSlot,
            HashSet<string> chest,
            HashSet<string> area)
        {
            AtomicWriteAllLines(chestPath, chest.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList());
            AtomicWriteAllLines(areaPath, area.OrderBy(x => x, StringComparer.OrdinalIgnoreCase).ToList());
            AtomicWriteAllLines(slotPath, new string[] { activeSlot });
        }

        private static readonly HashSet<long> OfficialChestExcludedSaveIds = new HashSet<long>();

        private static bool IsOfficialChestExcluded(long saveId)
        {
            return OfficialChestExcludedSaveIds.Contains(saveId);
        }

        private static readonly string[] ChestCategoryKeys = new string[]
        {
            "chests_grade1", "chests_grade2", "chests_grade3", "chests_grade4",
            "chests_grade5", "chests_key", "chests_map", "chests_puzzle_sep", "chests_minigame"
        };

        private static Dictionary<string, ChestCount> BuildChestCounts(List<MapEntry> mapping, HashSet<long> openedSaveIds)
        {
            Dictionary<string, ChestCount> result = new Dictionary<string, ChestCount>(StringComparer.OrdinalIgnoreCase);
            foreach (string category in ChestCategoryKeys) result[category] = new ChestCount();

            // Count unique save IDs per category so duplicate mapping rows can never inflate totals.
            foreach (IGrouping<string, MapEntry> group in mapping
                .Where(e => !String.IsNullOrWhiteSpace(e.Category) && IsChestCategory(e.Category))
                .GroupBy(e => e.Category, StringComparer.OrdinalIgnoreCase))
            {
                HashSet<long> ids = new HashSet<long>(group.Select(e => e.SaveId));
                ChestCount count;
                if (!result.TryGetValue(group.Key, out count))
                {
                    count = new ChestCount();
                    result[group.Key] = count;
                }
                count.Total = ids.Count;
                count.Opened = ids.Count(id => openedSaveIds.Contains(id));
            }
            return result;
        }

        private static void UpdateChestCountLabels(Paths paths, Dictionary<string, ChestCount> counts)
        {
            try
            {
                string langDir = Path.Combine(paths.MnmRoot, "lang");
                if (!Directory.Exists(langDir)) return;

                foreach (string file in Directory.GetFiles(langDir, "*.txt", SearchOption.TopDirectoryOnly))
                {
                    List<string> lines = File.ReadAllLines(file, Encoding.UTF8).ToList();
                    bool changed = false;
                    int totalOpened = 0, totalAll = 0;
                    foreach (ChestCount c in counts.Values) { totalOpened += c.Opened; totalAll += c.Total; }
                    HashSet<string> seenCategoryKeys = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    bool seenGroup = false;

                    for (int i = 0; i < lines.Count; i++)
                    {
                        string line = lines[i];
                        int eq = line.IndexOf('=');
                        if (eq < 0) continue;
                        string key = line.Substring(0, eq).Trim();
                        string value = line.Substring(eq + 1).Trim();

                        ChestCount c;
                        string categoryKey = key.StartsWith("cat.", StringComparison.OrdinalIgnoreCase)
                            ? key.Substring(4) : String.Empty;
                        // v1.18.14: chests_puzzle is the historical display alias, while
                        // the stable radar nodes deliberately use chests_puzzle_sep. Keep
                        // both labels on the same count so either UI key can never stay at 0.
                        string countKey = String.Equals(categoryKey, "chests_puzzle", StringComparison.OrdinalIgnoreCase)
                            ? "chests_puzzle_sep" : categoryKey;
                        if (categoryKey.Length > 0 && counts.TryGetValue(countKey, out c))
                        {
                            if (String.Equals(categoryKey, countKey, StringComparison.OrdinalIgnoreCase))
                                seenCategoryKeys.Add(categoryKey);
                            string baseValue = StripCountSuffix(value);
                            string suffix = FormatCountSuffix(file, c.Opened, c.Total);
                            string newLine = key + " = " + baseValue + suffix;
                            if (!String.Equals(line, newLine, StringComparison.Ordinal)) { lines[i] = newLine; changed = true; }
                        }
                        else if (String.Equals(key, "grp.chests", StringComparison.OrdinalIgnoreCase))
                        {
                            seenGroup = true;
                            string baseValue = StripCountSuffix(value);
                            string suffix = FormatCountSuffix(file, totalOpened, totalAll);
                            string newLine = key + " = " + baseValue + suffix;
                            if (!String.Equals(line, newLine, StringComparison.Ordinal)) { lines[i] = newLine; changed = true; }
                        }
                    }

                    // v1.18.9: keep the stable core binary unchanged. The core has an exact historical skip for
                    // chests_puzzle, so puzzle chests use the independent key chests_puzzle_sep instead;
                    // chests_minigame remains a separate reward-chest category.
                    foreach (string category in ChestCategoryKeys)
                    {
                        if (seenCategoryKeys.Contains(category)) continue;
                        ChestCount c;
                        if (!counts.TryGetValue(category, out c) || c.Total <= 0) continue;
                        lines.Add("cat." + category + " = " + DefaultChestLabel(file, category) + FormatCountSuffix(file, c.Opened, c.Total));
                        changed = true;
                    }
                    if (!seenGroup)
                    {
                        lines.Add("grp.chests = " + DefaultChestGroupLabel(file) + FormatCountSuffix(file, totalOpened, totalAll));
                        changed = true;
                    }

                    if (changed)
                        AtomicWriteAllLines(file, lines);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("宝箱数量标签更新失败（不影响宝箱核销）：" + ex.Message);
            }
        }

        private static string FormatCountSuffix(string file, int opened, int total)
        {
            // 0.4u: keep the rendered string length stable for MnMRadar's native
            // std::wstring translation cache. This allows safe in-place updates only.
            int width = Math.Max(1, total.ToString(CultureInfo.InvariantCulture).Length);
            string openedText = opened.ToString("D" + width.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
            string totalText = total.ToString(CultureInfo.InvariantCulture);
            if (IsChineseLanguageFile(file))
                return "（" + openedText + "/" + totalText + "）";
            return " (" + openedText + "/" + totalText + ")";
        }

        private static string DefaultChestLabel(string file, string category)
        {
            bool zh = IsChineseLanguageFile(file);
            if (zh)
            {
                if (String.Equals(category, "chests_puzzle_sep", StringComparison.OrdinalIgnoreCase)) return "谜题宝箱";
                if (String.Equals(category, "chests_minigame", StringComparison.OrdinalIgnoreCase)) return "小游戏宝箱";
                return category;
            }
            if (String.Equals(category, "chests_puzzle_sep", StringComparison.OrdinalIgnoreCase)) return "Puzzle Chest";
            if (String.Equals(category, "chests_minigame", StringComparison.OrdinalIgnoreCase)) return "Minigame Chest";
            return category;
        }

        private static string DefaultChestGroupLabel(string file)
        {
            return IsChineseLanguageFile(file) ? "宝箱类" : "Chests";
        }

        private static string StripCountSuffix(string value)
        {
            if (String.IsNullOrWhiteSpace(value)) return value;
            return Regex.Replace(value, @"\s*[（(]\s*\d+\s*/\s*\d+\s*[）)]\s*$", "").TrimEnd();
        }

        private static bool IsChineseLanguageFile(string path)
        {
            string name = Path.GetFileName(path).ToLowerInvariant();
            return name.StartsWith("zh-") || name == "zh.txt";
        }

        private static void WriteChestCountSummary(Paths paths, Dictionary<string, ChestCount> counts)
        {
            try
            {
                StringBuilder b = new StringBuilder();
                b.AppendLine("# DSWorldRadar v1.1 chest completion summary");
                b.AppendLine("# Generated=" + DateTime.Now.ToString("O", CultureInfo.InvariantCulture));
                int opened = 0, total = 0;
                foreach (string category in ChestCategoryKeys)
                {
                    ChestCount c;
                    if (!counts.TryGetValue(category, out c)) c = new ChestCount();
                    opened += c.Opened; total += c.Total;
                    b.AppendLine(category + "=" + c.Opened.ToString(CultureInfo.InvariantCulture) + "/" + c.Total.ToString(CultureInfo.InvariantCulture));
                }
                b.AppendLine("all=" + opened.ToString(CultureInfo.InvariantCulture) + "/" + total.ToString(CultureInfo.InvariantCulture));
                AtomicWriteAllLines(Path.Combine(paths.CacheRoot, "chest_counts.txt"), b.ToString().Split(new string[] { Environment.NewLine }, StringSplitOptions.None));
            }
            catch { }
        }

        private static HashSet<string> LoadTransientCompletionNodeIds(Paths paths)
        {
            // v1.18.29: the transient query universe remains exactly 161 nodes:
            // 34 fly + 40 mole + 10 wave + 48 true pressure/platform puzzles.
            // True SliderPuzzle is a separate 29-point runtime marker system and is intentionally
            // not carried through this numeric-ID progress set because 15001..15029 are reused.
            HashSet<string> result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string marmotPath = Path.Combine(paths.MnmRoot, "marmot_locations.csv");
                if (File.Exists(marmotPath))
                {
                    foreach (string raw in File.ReadAllLines(marmotPath, Encoding.UTF8).Skip(1))
                    {
                        string[] p = raw.Split(',');
                        if (p.Length < 2) continue;
                        string id = p[0].Trim(), kind = p[1].Trim();
                        if (kind.Equals("fly", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("mole", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("wave", StringComparison.OrdinalIgnoreCase))
                        {
                            if (id.Length > 0) result.Add(id);
                        }
                    }
                }

                string idsPath = Path.Combine(paths.MnmRoot, "mnm_ids.csv");
                if (File.Exists(idsPath))
                {
                    foreach (string raw in File.ReadAllLines(idsPath, Encoding.UTF8).Skip(1))
                    {
                        string[] p = raw.Split(',');
                        if (p.Length < 2) continue;
                        string id = p[0].Trim(), kind = p[1].Trim();
                        if (kind.Equals("puzzle_platform", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("puzzle_slider", StringComparison.OrdinalIgnoreCase))
                        {
                            if (id.Length > 0) result.Add(id);
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("跨存档完成态节点读取失败（已保持原 progress，不做危险清理）：" + ex.Message);
                result.Clear();
            }
            return result;
        }

        private static int PurgeTransientCompletionProgress(Paths paths, ref List<string> existingLines, HashSet<string> existing)
        {
            HashSet<string> transientIds = LoadTransientCompletionNodeIds(paths);
            if (transientIds.Count == 0) return 0;

            int removed = 0;
            List<string> kept = new List<string>();
            foreach (string line in existingLines)
            {
                if (transientIds.Contains(line))
                {
                    if (existing.Remove(line)) removed++;
                    continue;
                }
                kept.Add(line);
            }
            existingLines = kept;
            return removed;
        }

        private static Dictionary<string, ChestCount> BuildCompletionCounts(Paths paths, IEnumerable<string> progressLines)
        {
            HashSet<string> done = new HashSet<string>(progressLines ?? Enumerable.Empty<string>(), StringComparer.OrdinalIgnoreCase);
            Dictionary<string, HashSet<string>> idsByKind = new Dictionary<string, HashSet<string>>(StringComparer.OrdinalIgnoreCase);

            Action<string, string> add = (kind, id) =>
            {
                if (String.IsNullOrWhiteSpace(kind) || String.IsNullOrWhiteSpace(id)) return;
                HashSet<string> ids;
                if (!idsByKind.TryGetValue(kind, out ids))
                {
                    ids = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    idsByKind[kind] = ids;
                }
                ids.Add(id.Trim());
            };

            try
            {
                string marmotPath = Path.Combine(paths.MnmRoot, "marmot_locations.csv");
                if (File.Exists(marmotPath))
                {
                    foreach (string raw in File.ReadAllLines(marmotPath, Encoding.UTF8).Skip(1))
                    {
                        string[] p = raw.Split(',');
                        if (p.Length < 2) continue;
                        string id = p[0].Trim(), kind = p[1].Trim();
                        if (kind.Equals("fly", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("mole", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("wave", StringComparison.OrdinalIgnoreCase)) add(kind, id);
                    }
                }

                string idsPath = Path.Combine(paths.MnmRoot, "mnm_ids.csv");
                if (File.Exists(idsPath))
                {
                    foreach (string raw in File.ReadAllLines(idsPath, Encoding.UTF8).Skip(1))
                    {
                        string[] p = raw.Split(',');
                        if (p.Length < 2) continue;
                        string id = p[0].Trim(), kind = p[1].Trim();
                        if (kind.Equals("puzzle_platform", StringComparison.OrdinalIgnoreCase)
                            || kind.Equals("puzzle_slider", StringComparison.OrdinalIgnoreCase)) add(kind, id);
                    }
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("完成类节点统计读取失败（不影响雷达/核销）：" + ex.Message);
            }

            Dictionary<string, ChestCount> result = new Dictionary<string, ChestCount>(StringComparer.OrdinalIgnoreCase);
            foreach (KeyValuePair<string, HashSet<string>> kv in idsByKind)
            {
                ChestCount c = new ChestCount();
                c.Total = kv.Value.Count;
                c.Opened = kv.Value.Count(id => done.Contains(id));
                result[kv.Key] = c;
            }
            return result;
        }

        private static void UpdateCompletionCountLabels(Paths paths, IEnumerable<string> progressLines)
        {
            try
            {
                Dictionary<string, ChestCount> counts = BuildCompletionCounts(paths, progressLines);
                string langDir = Path.Combine(paths.MnmRoot, "lang");
                if (!Directory.Exists(langDir)) return;

                foreach (string file in Directory.GetFiles(langDir, "*.txt", SearchOption.TopDirectoryOnly))
                {
                    List<string> lines = File.ReadAllLines(file, Encoding.UTF8).ToList();
                    bool changed = false;
                    ChestCount fly = GetCompletionCount(counts, "fly");
                    ChestCount mole = GetCompletionCount(counts, "mole");
                    ChestCount wave = GetCompletionCount(counts, "wave");
                    ChestCount platform = GetCompletionCount(counts, "puzzle_platform");
                    ChestCount slider = GetCompletionCount(counts, "puzzle_slider");
                    ChestCount minigames = SumCounts(fly, mole, wave);
                    ChestCount puzzles = SumCounts(platform, slider);
                    ChestCount areaQuests = BuildSimpleProgressCount(paths, progressLines, "area_quests");

                    for (int i = 0; i < lines.Count; i++)
                    {
                        string line = lines[i];
                        int eq = line.IndexOf('=');
                        if (eq < 0) continue;
                        string key = line.Substring(0, eq).Trim();
                        string value = line.Substring(eq + 1).Trim();
                        ChestCount c = null;

                        if (String.Equals(key, "cat.fly", StringComparison.OrdinalIgnoreCase)) c = fly;
                        else if (String.Equals(key, "cat.mole", StringComparison.OrdinalIgnoreCase)) c = mole;
                        else if (String.Equals(key, "cat.wave", StringComparison.OrdinalIgnoreCase)) c = wave;
                        // v1.18.29: pressure (48) and true SliderPuzzle (29) are
                        // runtime/vector-authoritative. Do not overwrite any puzzle label
                        // from numeric progress.txt because 15001..15029 are reused by
                        // the two independent systems.
                        else if (String.Equals(key, "grp.minigames", StringComparison.OrdinalIgnoreCase)) c = minigames;
                        else if (String.Equals(key, "cat.area_quests", StringComparison.OrdinalIgnoreCase)) c = areaQuests;

                        if (c != null && c.Total > 0)
                        {
                            string baseValue = StripCountSuffix(value);
                            string newLine = key + " = " + baseValue + FormatCountSuffix(file, c.Opened, c.Total);
                            if (!String.Equals(line, newLine, StringComparison.Ordinal))
                            {
                                lines[i] = newLine;
                                changed = true;
                            }
                        }
                    }

                    if (changed) AtomicWriteAllLines(file, lines);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("完成类数量标签更新失败（不影响雷达/宝箱核销）：" + ex.Message);
            }
        }

        private static ChestCount GetCompletionCount(Dictionary<string, ChestCount> counts, string key)
        {
            ChestCount c;
            if (counts.TryGetValue(key, out c)) return c;
            return new ChestCount();
        }

        private static ChestCount SumCounts(params ChestCount[] items)
        {
            ChestCount r = new ChestCount();
            foreach (ChestCount c in items)
            {
                if (c == null) continue;
                r.Opened += c.Opened;
                r.Total += c.Total;
            }
            return r;
        }

        private static void WriteCompletionCountSummary(Paths paths, IEnumerable<string> progressLines)
        {
            try
            {
                Dictionary<string, ChestCount> counts = BuildCompletionCounts(paths, progressLines);
                ChestCount fly = GetCompletionCount(counts, "fly");
                ChestCount mole = GetCompletionCount(counts, "mole");
                ChestCount wave = GetCompletionCount(counts, "wave");
                ChestCount platform = GetCompletionCount(counts, "puzzle_platform");
                ChestCount slider = GetCompletionCount(counts, "puzzle_slider");
                ChestCount minigames = SumCounts(fly, mole, wave);
                ChestCount puzzles = SumCounts(platform, slider);
                ChestCount areaQuests = BuildSimpleProgressCount(paths, progressLines, "area_quests");

                StringBuilder b = new StringBuilder();
                b.AppendLine("# DSWorldRadar v1.1 completion summary (MnM progress-backed)");
                b.AppendLine("# Generated=" + DateTime.Now.ToString("O", CultureInfo.InvariantCulture));
                b.AppendLine("fly=" + fly.Opened + "/" + fly.Total);
                b.AppendLine("mole=" + mole.Opened + "/" + mole.Total);
                b.AppendLine("wave=" + wave.Opened + "/" + wave.Total);
                b.AppendLine("minigames=" + minigames.Opened + "/" + minigames.Total);
                b.AppendLine("puzzle_platform=" + platform.Opened + "/" + platform.Total);
                b.AppendLine("puzzle_slider=" + slider.Opened + "/" + slider.Total);
                b.AppendLine("puzzles=" + puzzles.Opened + "/" + puzzles.Total);
                b.AppendLine("area_quests=" + areaQuests.Opened + "/" + areaQuests.Total);
                File.WriteAllText(Path.Combine(paths.CacheRoot, "completion_counts.txt"), b.ToString(), new UTF8Encoding(false));
            }
            catch { }
        }

        private static HashSet<string> LoadNodeIdsByKind(Paths paths, string wantedKind)
        {
            HashSet<string> result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string idsPath = Path.Combine(paths.MnmRoot, "mnm_ids.csv");
                if (!File.Exists(idsPath)) return result;
                foreach (string raw in File.ReadAllLines(idsPath, Encoding.UTF8).Skip(1))
                {
                    string[] p = raw.Split(',');
                    if (p.Length < 2) continue;
                    string id = p[0].Trim();
                    string kind = p[1].Trim();
                    if (id.Length > 0 && kind.Equals(wantedKind, StringComparison.OrdinalIgnoreCase))
                        result.Add(id);
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine("节点 ID 读取失败（" + wantedKind + "，不影响宝箱核销）：" + ex.Message);
            }
            return result;
        }

        private static ChestCount BuildSimpleProgressCount(Paths paths, IEnumerable<string> progressLines, string kind)
        {
            HashSet<string> ids = LoadNodeIdsByKind(paths, kind);
            HashSet<string> done = new HashSet<string>(
                progressLines == null ? new string[0] : progressLines,
                StringComparer.OrdinalIgnoreCase);
            ChestCount c = new ChestCount();
            c.Total = ids.Count;
            c.Opened = ids.Count(id => done.Contains(id));
            return c;
        }

        private static bool IsChestCategory(string category)
        {
            return !String.IsNullOrWhiteSpace(category)
                && category.StartsWith("chests_", StringComparison.OrdinalIgnoreCase);
        }

        private static string Sha256File(string path)
        {
            using (SHA256 sha = SHA256.Create())
            using (FileStream f = File.OpenRead(path))
            {
                return BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "").ToLowerInvariant();
            }
        }

        private static SaveSelection FindFastLiveSave(Paths paths)
        {
            string hintPath=Path.Combine(paths.CacheRoot,"fast_profile_hint_slot.txt");
            string claimed=hintPath+".read_"+Guid.NewGuid().ToString("N");
            try
            {
                if(File.Exists(hintPath))
                {
                    File.Move(hintPath,claimed);
                    DateTime age=File.GetLastWriteTimeUtc(claimed);
                    if((DateTime.UtcNow-age).TotalSeconds<=20.0)
                    {
                        string hinted=File.ReadAllText(claimed).Trim();
                        if(hinted.Length>0)
                        {
                            hinted=Path.GetFullPath(hinted);
                            string root=Path.GetFullPath(paths.SaveGamesRoot).TrimEnd(Path.DirectorySeparatorChar,Path.AltDirectorySeparatorChar)+Path.DirectorySeparatorChar;
                            if(hinted.StartsWith(root,StringComparison.OrdinalIgnoreCase)
                                && String.Equals(Path.GetExtension(hinted),".db",StringComparison.OrdinalIgnoreCase)
                                && Path.GetFileName(hinted).IndexOf("_Slot",StringComparison.OrdinalIgnoreCase)>=0
                                && File.Exists(hinted))
                            {
                                List<string> related=new List<string>();related.Add(hinted);
                                string bak=Path.ChangeExtension(hinted,".bak");if(File.Exists(bak))related.Add(bak);
                                SaveSelection selected=new SaveSelection();
                                selected.Path=hinted;selected.WriteTime=File.GetLastWriteTimeUtc(hinted);
                                selected.DisplayName=Path.GetFileName(hinted);selected.RelatedPaths=related;
                                Console.WriteLine("FAST_SLOT_HINT_ACCEPTED=1");
                                Console.WriteLine("FAST_SLOT_HINT_FILE="+selected.DisplayName);
                                return selected;
                            }
                        }
                    }
                }
            }
            catch(Exception ex){Console.WriteLine("FAST_SLOT_HINT_SKIP="+ex.GetType().Name);}
            finally{TryDelete(claimed);}
            Console.WriteLine("FAST_SLOT_HINT_ACCEPTED=0");
            return FindNewestSave(paths.SaveGamesRoot);
        }

        private static SaveSelection FindNewestSave(string saveRoot)
        {
            if (!Directory.Exists(saveRoot)) throw new DirectoryNotFoundException("未找到存档目录：" + saveRoot);
            List<string> candidates = Directory.GetFiles(saveRoot, "*_Slot*.db", SearchOption.AllDirectories)
                .Concat(Directory.GetFiles(saveRoot, "*_Slot*.bak", SearchOption.AllDirectories))
                .ToList();
            if (candidates.Count == 0) throw new FileNotFoundException("存档目录中没有找到 *_Slot*.db 或 *_Slot*.bak。", saveRoot);

            var active = candidates.GroupBy(p => Path.Combine(Path.GetDirectoryName(p), Path.GetFileNameWithoutExtension(p)), StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(g => g.Max(p => File.GetLastWriteTimeUtc(p)))
                .First();
            List<string> relatedByTime = active
                .OrderByDescending(p => File.GetLastWriteTimeUtc(p))
                .ToList();

            // v2.7: .db 始终是主存档；.bak 只能作为补充来源。
            // 这样即使 .bak 的修改时间更晚，也不会反客为主。
            string selected = relatedByTime.FirstOrDefault(
                p => String.Equals(Path.GetExtension(p), ".db", StringComparison.OrdinalIgnoreCase));
            if (selected == null) selected = relatedByTime[0];

            List<string> related = new List<string>();
            related.Add(selected);
            foreach (string p in relatedByTime)
                if (!String.Equals(p, selected, StringComparison.OrdinalIgnoreCase))
                    related.Add(p);

            SaveSelection s = new SaveSelection();
            s.Path = selected;
            s.WriteTime = File.GetLastWriteTimeUtc(selected);
            s.DisplayName = Path.GetFileName(selected);
            s.RelatedPaths = related;
            return s;
        }

        private static void DecryptSqlCipher(string inputPath, string outputPath)
        {
            const int pageSize = 4096;
            const int reserve = 80;
            const int ivSize = 16;
            byte[] data = File.ReadAllBytes(inputPath);
            if (data.Length == 0 || data.Length % pageSize != 0) throw new InvalidDataException("存档大小不是 4096 字节页的整数倍，无法按当前 SQLCipher 格式读取。");

            byte[] salt = new byte[16];
            Buffer.BlockCopy(data, 0, salt, 0, 16);
            byte[] key = Pbkdf2Sha512(SqlCipherPass, salt, 256000, 32);
            byte[] header = Encoding.ASCII.GetBytes("SQLite format 3\0");

            using (FileStream output = File.Create(outputPath))
            using (Aes aes = Aes.Create())
            {
                aes.Mode = CipherMode.CBC;
                aes.Padding = PaddingMode.None;
                aes.Key = key;

                int pages = data.Length / pageSize;
                for (int pn = 1; pn <= pages; pn++)
                {
                    int st = (pn - 1) * pageSize;
                    int ctStart = st + (pn == 1 ? 16 : 0);
                    int ctEnd = st + pageSize - reserve;
                    byte[] iv = new byte[ivSize];
                    Buffer.BlockCopy(data, ctEnd, iv, 0, ivSize);
                    int ctLen = ctEnd - ctStart;
                    byte[] ct = new byte[ctLen];
                    Buffer.BlockCopy(data, ctStart, ct, 0, ctLen);
                    byte[] pt;
                    using (ICryptoTransform dec = aes.CreateDecryptor(key, iv))
                    {
                        pt = dec.TransformFinalBlock(ct, 0, ct.Length);
                    }
                    if (pn == 1) output.Write(header, 0, header.Length);
                    output.Write(pt, 0, pt.Length);
                    byte[] zeros = new byte[reserve];
                    output.Write(zeros, 0, zeros.Length);
                }
            }
        }

        private static byte[] Pbkdf2Sha512(byte[] password, byte[] salt, int iterations, int length)
        {
            using (HMACSHA512 hmac = new HMACSHA512(password))
            {
                int hashLength = hmac.HashSize / 8;
                int blocks = (int)Math.Ceiling((double)length / hashLength);
                byte[] output = new byte[blocks * hashLength];
                int outOffset = 0;
                for (int block = 1; block <= blocks; block++)
                {
                    byte[] saltBlock = new byte[salt.Length + 4];
                    Buffer.BlockCopy(salt, 0, saltBlock, 0, salt.Length);
                    saltBlock[salt.Length] = (byte)((block >> 24) & 0xFF);
                    saltBlock[salt.Length + 1] = (byte)((block >> 16) & 0xFF);
                    saltBlock[salt.Length + 2] = (byte)((block >> 8) & 0xFF);
                    saltBlock[salt.Length + 3] = (byte)(block & 0xFF);

                    byte[] u = hmac.ComputeHash(saltBlock);
                    byte[] t = (byte[])u.Clone();
                    for (int i = 1; i < iterations; i++)
                    {
                        u = hmac.ComputeHash(u);
                        for (int j = 0; j < t.Length; j++) t[j] ^= u[j];
                    }
                    Buffer.BlockCopy(t, 0, output, outOffset, t.Length);
                    outOffset += t.Length;
                }
                byte[] result = new byte[length];
                Buffer.BlockCopy(output, 0, result, 0, length);
                return result;
            }
        }

        private static void AtomicWriteAllLines(string path, IList<string> lines)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path));
            string temp = path + ".sync_tmp_" + Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture);
            TryDelete(temp);
            File.WriteAllLines(temp, lines, new UTF8Encoding(false));

            if (!File.Exists(path))
            {
                File.Move(temp, path);
                return;
            }

            // v2.1.0: never delete the live progress.txt before replacement.
            // File.Replace keeps the destination continuously present on NTFS and avoids
            // the short missing-file window that could race MnMRadar while the game is running.
            Exception last = null;
            for (int attempt = 1; attempt <= 20; attempt++)
            {
                try
                {
                    File.Replace(temp, path, null, true);
                    return;
                }
                catch (IOException ex)
                {
                    last = ex;
                    System.Threading.Thread.Sleep(50);
                }
                catch (UnauthorizedAccessException ex)
                {
                    last = ex;
                    System.Threading.Thread.Sleep(50);
                }
            }

            TryDelete(temp);
            throw new IOException("progress.txt 原子替换失败；已保留原文件不动。", last);
        }

        private static string ResolveGameRoot(string explicitRoot, string toolRoot)
        {
            if (!String.IsNullOrWhiteSpace(explicitRoot))
            {
                string root = Path.GetFullPath(explicitRoot.Trim().Trim('"').TrimEnd(Path.DirectorySeparatorChar));
                if (LooksLikeGameRoot(root)) return root;
                throw new DirectoryNotFoundException("指定路径不是有效的《龙之剑：觉醒》游戏根目录：" + root);
            }

            DirectoryInfo d = new DirectoryInfo(toolRoot);
            for (int i = 0; i < 16 && d != null; i++, d = d.Parent)
            {
                if (LooksLikeGameRoot(d.FullName)) return d.FullName;
            }
            throw new DirectoryNotFoundException("无法自动找到游戏根目录。已从当前同步组件位置向上检查 16 层目录，请确认 DSWorldRadar 位于当前游戏的新 UE4SS Mods 目录下。");
        }

        private static bool LooksLikeGameRoot(string root)
        {
            return File.Exists(Path.Combine(root, "DS", "Binaries", "Win64", GameExeName))
                && Directory.Exists(Path.Combine(root, "DS", "Content", "Paks"));
        }

        private static bool HasFlag(string[] args, string flag)
        {
            return args.Any(a => String.Equals(a, flag, StringComparison.OrdinalIgnoreCase));
        }

        private static string GetOption(string[] args, string name)
        {
            for (int i = 0; i < args.Length; i++)
            {
                if (String.Equals(args[i], name, StringComparison.OrdinalIgnoreCase) && i + 1 < args.Length) return args[i + 1];
                if (args[i].StartsWith(name + "=", StringComparison.OrdinalIgnoreCase)) return args[i].Substring(name.Length + 1);
            }
            return null;
        }

        private static void TryDelete(string path) { try { if (File.Exists(path)) File.Delete(path); } catch { } }

        private static void WriteEmergencyLog(Exception ex)
        {
            try
            {
                string path = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "sync_error.txt");
                File.WriteAllText(path, DateTime.Now.ToString("O") + Environment.NewLine + ex.ToString(), new UTF8Encoding(false));
                Console.WriteLine("错误详情已写入：" + path);
            }
            catch { }
        }

        private sealed class Paths
        {
            public readonly string GameRoot, ToolRoot, Win64Root, GameExePath, SaveGamesRoot;
            public readonly string MnmRoot, MnmNodesPath, MnmCatalogPath, ProgressPath, CacheRoot;
            public Paths(string gameRoot, string toolRoot)
            {
                GameRoot=gameRoot; ToolRoot=toolRoot;
                Win64Root=Path.Combine(gameRoot,"DS","Binaries","Win64");
                GameExePath=Path.Combine(Win64Root,GameExeName);
                SaveGamesRoot=Path.Combine(gameRoot,"DS","Saved","SaveGames");
                string local=Path.GetFullPath(Path.Combine(toolRoot,".."));
                string unified=Path.Combine(Win64Root,"ue4ss","Mods","DSWorldRadar","dlls");
                MnmRoot=File.Exists(Path.Combine(local,"mnm_nodes.csv")) ? local : unified;
                MnmNodesPath=Path.Combine(MnmRoot,"mnm_nodes.csv");
                MnmCatalogPath=MnmNodesPath; ProgressPath=Path.Combine(MnmRoot,"progress.txt");
                CacheRoot=Path.Combine(toolRoot,"cache");
            }
            public void Validate(bool unused)
            {
                if(!File.Exists(GameExePath)) throw new FileNotFoundException("未找到游戏主程序。",GameExePath);
                if(!File.Exists(MnmNodesPath)) throw new FileNotFoundException("未找到 DSWorldRadar 完整节点目录。",MnmNodesPath);
            }
        }

        private sealed class ChestCount
        {
            public int Opened;
            public int Total;
        }

        private sealed class MapEntry
        {
            public long SaveId;
            public string NodeId;
            public double Distance;
            public string Stage;
            public string Category;
        }

        private sealed class SaveSelection
        {
            public string Path;
            public string DisplayName;
            public DateTime WriteTime;
            public List<string> RelatedPaths;
        }

        private static class WinSqlite
        {
        private const int SQLITE_OPEN_READONLY = 1;

        [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int ExecCallback(IntPtr data, int argc, IntPtr argv, IntPtr colNames);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_open_v2(byte[] filename, out IntPtr db, int flags, IntPtr zvfs);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_close_v2(IntPtr db);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern int sqlite3_exec(IntPtr db, byte[] sql, ExecCallback callback, IntPtr arg, out IntPtr errmsg);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern void sqlite3_free(IntPtr p);

        [DllImport("winsqlite3.dll", CallingConvention = CallingConvention.Cdecl)] private static extern IntPtr sqlite3_errmsg(IntPtr db);

        public static HashSet<long> ReadOpenedIds(string plainDb)
            {
                HashSet<long> opened = new HashSet<long>(); IntPtr db = IntPtr.Zero;
                try
                {
                    int rc = sqlite3_open_v2(Utf8Z(plainDb), out db, SQLITE_OPEN_READONLY, IntPtr.Zero);
                    if (rc != 0) throw new InvalidOperationException("Windows SQLite 无法打开解密后的存档：" + Error(db));
                    ExecCallback cb = delegate(IntPtr data, int argc, IntPtr argv, IntPtr names)
                    {
                        if (argc >= 2)
                        {
                            string c = PtrUtf8(Marshal.ReadIntPtr(argv, 0));
                            string f = PtrUtf8(Marshal.ReadIntPtr(argv, IntPtr.Size));
                            int category; long signed;
                            if (int.TryParse(c, NumberStyles.Integer, CultureInfo.InvariantCulture, out category)
                                && long.TryParse(f, NumberStyles.Integer, CultureInfo.InvariantCulture, out signed))
                            {
                                ulong bits = unchecked((ulong)signed);
                                for (int bit = 0; bit < 64; bit++) if ((bits & (1UL << bit)) != 0) opened.Add(category * 64L + bit);
                            }
                        }
                        return 0;
                    };
                    IntPtr err;
                    rc = sqlite3_exec(db, Utf8Z("SELECT CATEGORY,OPENED_BIT_FIELD FROM tb_treasure_box;"), cb, IntPtr.Zero, out err);
                    GC.KeepAlive(cb);
                    if (rc != 0)
                    {
                        string msg = err != IntPtr.Zero ? PtrUtf8(err) : Error(db);
                        if (err != IntPtr.Zero) sqlite3_free(err);
                        throw new InvalidOperationException("读取 tb_treasure_box 失败：" + msg);
                    }
                    return opened;
                }
                finally { if (db != IntPtr.Zero) sqlite3_close_v2(db); }
            }

        public static HashSet<long> ReadCompletedQuestIds(string plainDb)
            {
                HashSet<long> result = new HashSet<long>();
                IntPtr db = IntPtr.Zero;
                try
                {
                    int rc = sqlite3_open_v2(Utf8Z(plainDb), out db, SQLITE_OPEN_READONLY, IntPtr.Zero);
                    if (rc != 0) throw new InvalidOperationException("Windows SQLite 无法打开解密后的存档：" + Error(db));

                    ReadLongColumnOptional(db, "SELECT QUEST_CID FROM tb_completed_quest;", result);
                    ReadLongColumnOptional(db, "SELECT QUEST_CID FROM tb_quest_complete;", result);
                    ReadLongColumnOptional(db, "SELECT QUEST_ID FROM tb_dynamic_quest_complete WHERE IFNULL(COMPLETE_CNT,0)>0;", result);
                    return result;
                }
                finally
                {
                    if (db != IntPtr.Zero) sqlite3_close_v2(db);
                }
            }

        private static void ReadLongColumnOptional(IntPtr db, string sql, HashSet<long> target)
            {
                ExecCallback cb = delegate(IntPtr data, int argc, IntPtr argv, IntPtr names)
                {
                    if (argc >= 1)
                    {
                        string s = PtrUtf8(Marshal.ReadIntPtr(argv, 0));
                        long v;
                        if (Int64.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out v))
                            target.Add(v);
                    }
                    return 0;
                };
                IntPtr err;
                int rc = sqlite3_exec(db, Utf8Z(sql), cb, IntPtr.Zero, out err);
                GC.KeepAlive(cb);
                if (rc != 0)
                {
                    string message = err != IntPtr.Zero ? PtrUtf8(err) : Error(db);
                    if (err != IntPtr.Zero) sqlite3_free(err);
                    if (!message.StartsWith("no such table:", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidOperationException("读取任务完成记录失败：" + message);
                }
            }

        private static string Error(IntPtr db) { return db == IntPtr.Zero ? "unknown" : PtrUtf8(sqlite3_errmsg(db)); }

        private static byte[] Utf8Z(string s) { return Encoding.UTF8.GetBytes(s + "\0"); }

        private static string PtrUtf8(IntPtr p) { if (p == IntPtr.Zero) return String.Empty; int n = 0; while (Marshal.ReadByte(p, n) != 0) n++; byte[] b = new byte[n]; Marshal.Copy(p, b, 0, n); return Encoding.UTF8.GetString(b); }
        }
        }
}
