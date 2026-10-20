param([string]$SourcePath,[string]$FixturesPath,[string]$OutputPath)
$ErrorActionPreference='Stop'
$f=Get-Content -LiteralPath $FixturesPath -Raw|ConvertFrom-Json
$source=[IO.File]::ReadAllText((Resolve-Path $SourcePath))
$adapter=@'
public static class RadarReviewHelperTests {
    public static readonly System.Collections.Generic.List<string> Passed = new System.Collections.Generic.List<string>();
    private static System.Type program;
    private static System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic;
    private static object paths;
    private static string tool;
    private static string replacementHint;
    private sealed class CapturedOutput : System.IO.StringWriter {
        public override void WriteLine(string line) {
            base.WriteLine(line);
            if(line=="FAST_SLOT_HINT_ACCEPTED=1" && replacementHint!=null){
                System.IO.File.WriteAllText(System.IO.Path.Combine(tool,"cache","fast_profile_hint_slot.txt"),replacementHint);
                replacementHint=null;
            }
        }
    }
    private static void Check(bool ok,string name) { if(!ok) throw new System.Exception(name); Passed.Add(name); }
    private static object Invoke(string name,params object[] args) {
        try { return program.GetMethod(name,flags).Invoke(null,args); }
        catch(System.Reflection.TargetInvocationException e) { throw e.InnerException; }
    }
    private static System.IntPtr Resolve(string name,System.Reflection.Assembly a,System.Runtime.InteropServices.DllImportSearchPath? p) {
        if(name=="winsqlite3.dll") return System.Runtime.InteropServices.NativeLibrary.Load("libsqlite3.so.0");
        return System.IntPtr.Zero;
    }
    public static void Setup(System.Reflection.Assembly assembly,string game,string toolRoot) {
        program=assembly.GetType("MnMChestSaveSync.Program");tool=toolRoot;
        System.Runtime.InteropServices.NativeLibrary.SetDllImportResolver(assembly,Resolve);
        var t=program.GetNestedType("Paths",System.Reflection.BindingFlags.NonPublic);
        paths=System.Activator.CreateInstance(t,new object[]{game,toolRoot});
    }
    private static string State() { return System.IO.File.ReadAllText(System.IO.Path.Combine(tool,"cache","authority_state.v1.txt")); }
    private static string Sync(string save,bool seed,bool reload) {
        System.IO.Directory.CreateDirectory(System.IO.Path.Combine(tool,"cache"));
        System.IO.File.WriteAllText(System.IO.Path.Combine(tool,"cache","fast_profile_hint_slot.txt"),save);
        var output=new CapturedOutput();var before=System.Console.Out;
        try {System.Console.SetOut(output);Invoke("FastLiveSynchronize",paths,seed,reload);}
        finally {System.Console.SetOut(before);}
        return output.ToString();
    }
    public static void Run(string a,string b,string empty,string malformed,string corrupt,string positive,string zero,string negative) {
        Sync(a,true,false);
        string stateA=State();
        Check(stateA.Split('\n').Length>=6 && stateA.Contains("DSC_11230106"),"A seed includes 1503rd chest in a complete atomic state");
        Check(stateA.Contains("areas="+positive) && !stateA.Contains("areas="+zero) && !stateA.Contains("areas="+negative),"dynamic quest COMPLETE_CNT zero/negative are not completion");
        replacementHint=b;Sync(a,false,false);
        Check(System.IO.File.ReadAllText(System.IO.Path.Combine(tool,"cache","fast_profile_hint_slot.txt"))==b,"a newer transition hint is not deleted by an earlier sync");
        string output=Sync(b,false,true);
        string stateB=State();
        Check(output.Contains("FAST_BOUNDARY_FULLSTATE=1") && !stateB.Contains("DSC_11230106"),"A to B emits boundary and restores unopened new chest");
        Check(!System.IO.File.ReadAllText(System.IO.Path.Combine(System.IO.Path.GetDirectoryName(tool),"progress.txt")).Contains("DSC_11230106"),"B removes stale chest completion from progress");
        string count=System.IO.File.ReadAllText(System.IO.Path.Combine(tool,"cache","chest_counts.txt"));
        Check(count.Contains("chests_grade3=348/349") && count.Contains("all=1502/1503"),"B authoritative counts are 348/349 and 1502/1503");
        Sync(a,false,true);
        Check(State().Contains("DSC_11230106"),"B to A restores opened chest");
        Sync(empty,false,true);
        Check(State().Contains("chests=\n") && System.IO.File.ReadAllText(System.IO.Path.Combine(tool,"cache","chest_counts.txt")).Contains("all=0/1503"),"valid zero-open save remains valid");
        Sync(a,false,true);string committed=State();
        bool failed=false;try{Sync(corrupt,false,false);}catch{failed=true;}
        Check(failed && State()==committed,"unreadable primary never commits older valid backup state");
        failed=false;try{Sync(malformed,false,false);}catch{failed=true;}
        Check(failed && State()==committed,"malformed quest schema fails closed without clearing state");
        string beforeState=State();Invoke("FastProgressOnly",paths);
        Check(State()==beforeState,"progress-only count refresh never changes save authority");
        Check(!System.IO.Directory.Exists(System.IO.Path.Combine(tool,"save_profiles_v2")),"retired duplicate helper profile tree is not regenerated");
        Check(System.IO.Directory.GetFiles(System.IO.Path.Combine(tool,"cache"),"fast_plain_*.db").Length==0,"decrypted temporary saves are removed on success and failure");
        var leaseType=program.GetNestedType("SyncWriteLease",System.Reflection.BindingFlags.NonPublic);
        var lease=(System.IDisposable)System.Activator.CreateInstance(leaseType,new object[]{tool});
        var attempted=new System.Threading.ManualResetEventSlim(false);
        var acquired=new System.Threading.ManualResetEventSlim(false);
        var contender=System.Threading.Tasks.Task.Run(()=>{attempted.Set();using(var other=(System.IDisposable)System.Activator.CreateInstance(leaseType,new object[]{tool})){acquired.Set();}});
        attempted.Wait();bool enteredTooEarly=acquired.Wait(200);lease.Dispose();contender.Wait();
        Check(!enteredTooEarly && acquired.IsSet,"same-install helper lock excludes overlapping writers and releases correctly");
    }
}
'@
Add-Type -TypeDefinition ($source+"`n"+$adapter) -ErrorAction Stop
$type=[AppDomain]::CurrentDomain.GetAssemblies()|ForEach-Object {$_.GetType('MnMChestSaveSync.Program')}|Where-Object {$null -ne $_}|Select-Object -First 1
[RadarReviewHelperTests]::Setup($type.Assembly,$f.game,$f.tool)
[RadarReviewHelperTests]::Run($f.A,$f.B,$f.empty,$f.malformed,$f.corrupt,$f.area_positive,$f.area_zero,$f.area_negative)
@{passed=$true;checks=@([RadarReviewHelperTests]::Passed);source_sha256=(Get-FileHash -LiteralPath $SourcePath -Algorithm SHA256).Hash.ToLowerInvariant();runtime='compiled production C# under .NET via PowerShell 7.4.6; Linux SQLite library resolved for Windows import';synthetic_saves_only=$true;game_runtime_executed=$false}|ConvertTo-Json -Depth 4|Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Output ('PASS: '+[RadarReviewHelperTests]::Passed.Count+' compiled-helper execution checks')
