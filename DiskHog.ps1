# Disk Hog - finds what is eating your drive space.
# Run it with "Run Disk Hog.bat". Read-only: it never deletes or changes anything.

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Disk Hog' } catch {}

function Format-Size([double]$b) {
    $u = 'B','KB','MB','GB','TB'; $i = 0
    while ($b -ge 1024 -and $i -lt 4) { $b /= 1024; $i++ }
    return ('{0:N1} {1}' -f $b, $u[$i])
}

try {
Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;

public class DHNode
{
    public string Name;
    public long Size;
    public long Files;
    public int Denied;
    public List<DHNode> Kids = new List<DHNode>();
    public List<KeyValuePair<string, long>> Big = new List<KeyValuePair<string, long>>();
}

public class DHScanner
{
    // Tuning
    public long KeepFolderMin = 5L * 1024 * 1024;      // keep folders >= 5 MB in the tree
    public long BigFileMin = 25L * 1024 * 1024;        // list files >= 25 MB inside folders
    public int MaxKids = 80;
    public int MaxBigPerFolder = 40;
    public int TopFileCount = 250;

    public long TotalFiles = 0;
    public long TotalDirs = 0;
    public long TotalDenied = 0;
    public Dictionary<string, long[]> Ext = new Dictionary<string, long[]>(StringComparer.OrdinalIgnoreCase);
    public List<KeyValuePair<string, long>> Top = new List<KeyValuePair<string, long>>();
    private long topMin = 0;
    private Stopwatch clock = new Stopwatch();
    private long lastTick = 0;

    public DHNode Scan(string root)
    {
        clock.Start();
        DHNode n = Walk(new DirectoryInfo(root), root, root.TrimEnd('\\', '/'));
        Console.WriteLine();
        return n;
    }

    private DHNode Walk(DirectoryInfo dir, string fullPath, string name)
    {
        DHNode node = new DHNode();
        node.Name = name;
        TotalDirs++;

        if (clock.ElapsedMilliseconds - lastTick > 500)
        {
            lastTick = clock.ElapsedMilliseconds;
            string shown = fullPath.Length > 70 ? "..." + fullPath.Substring(fullPath.Length - 67) : fullPath;
            Console.Write("\r  {0,12:N0} files  |  {1}", TotalFiles, shown.PadRight(70));
        }

        IEnumerable<FileSystemInfo> entries;
        try { entries = dir.EnumerateFileSystemInfos(); }
        catch { node.Denied = 1; TotalDenied++; return node; }

        IEnumerator<FileSystemInfo> it;
        try { it = entries.GetEnumerator(); }
        catch { node.Denied = 1; TotalDenied++; return node; }

        while (true)
        {
            FileSystemInfo e;
            try
            {
                if (!it.MoveNext()) break;
                e = it.Current;
            }
            catch { node.Denied = 1; TotalDenied++; break; }

            try
            {
                FileAttributes a = e.Attributes;
                if ((a & FileAttributes.Directory) != 0)
                {
                    // Skip junctions/symlinks so nothing gets counted twice
                    if ((a & FileAttributes.ReparsePoint) != 0) continue;
                    DirectoryInfo sub = (DirectoryInfo)e;
                    DHNode child = Walk(sub, sub.FullName, sub.Name);
                    node.Size += child.Size;
                    node.Files += child.Files;
                    node.Denied += child.Denied;
                    if (child.Size >= KeepFolderMin) node.Kids.Add(child);
                }
                else
                {
                    FileInfo f = (FileInfo)e;
                    long len = f.Length;
                    node.Size += len;
                    node.Files++;
                    TotalFiles++;

                    string ext = f.Extension;
                    if (string.IsNullOrEmpty(ext)) ext = "(none)";
                    long[] s;
                    if (!Ext.TryGetValue(ext, out s)) { s = new long[2]; Ext[ext] = s; }
                    s[0] += len; s[1]++;

                    if (len >= BigFileMin) node.Big.Add(new KeyValuePair<string, long>(f.Name, len));
                    if (len > topMin || Top.Count < TopFileCount) AddTop(f.FullName, len);
                }
            }
            catch { node.Denied++; TotalDenied++; }
        }

        node.Kids.Sort(delegate(DHNode x, DHNode y) { return y.Size.CompareTo(x.Size); });
        if (node.Kids.Count > MaxKids) node.Kids.RemoveRange(MaxKids, node.Kids.Count - MaxKids);
        node.Big.Sort(delegate(KeyValuePair<string, long> x, KeyValuePair<string, long> y) { return y.Value.CompareTo(x.Value); });
        if (node.Big.Count > MaxBigPerFolder) node.Big.RemoveRange(MaxBigPerFolder, node.Big.Count - MaxBigPerFolder);
        return node;
    }

    private void AddTop(string path, long len)
    {
        Top.Add(new KeyValuePair<string, long>(path, len));
        if (Top.Count >= TopFileCount * 2)
        {
            SortTop();
            Top.RemoveRange(TopFileCount, Top.Count - TopFileCount);
            topMin = Top[Top.Count - 1].Value;
        }
    }

    public void SortTop()
    {
        Top.Sort(delegate(KeyValuePair<string, long> x, KeyValuePair<string, long> y) { return y.Value.CompareTo(x.Value); });
        if (Top.Count > TopFileCount) Top.RemoveRange(TopFileCount, Top.Count - TopFileCount);
    }

    // ---------- JSON output ----------
    public static string Esc(string s)
    {
        StringBuilder b = new StringBuilder(s.Length + 8);
        b.Append('"');
        foreach (char c in s)
        {
            if (c == '"') b.Append("\\\"");
            else if (c == '\\') b.Append("\\\\");
            else if (c < 0x20 || c == '<' || c == '>' || c == '&' || c == (char)0x2028 || c == (char)0x2029)
                b.Append("\\u").Append(((int)c).ToString("x4"));
            else b.Append(c);
        }
        b.Append('"');
        return b.ToString();
    }

    public static void NodeJson(DHNode n, StringBuilder b)
    {
        // [name, size, files, denied, [kids], [[file,size],...]]
        b.Append('[').Append(Esc(n.Name)).Append(',').Append(n.Size).Append(',').Append(n.Files).Append(',').Append(n.Denied).Append(",[");
        for (int i = 0; i < n.Kids.Count; i++) { if (i > 0) b.Append(','); NodeJson(n.Kids[i], b); }
        b.Append("],[");
        for (int i = 0; i < n.Big.Count; i++)
        {
            if (i > 0) b.Append(',');
            b.Append('[').Append(Esc(n.Big[i].Key)).Append(',').Append(n.Big[i].Value).Append(']');
        }
        b.Append("]]");
    }

    public string DriveJson(DHNode root, string label, long total, long free, double seconds)
    {
        SortTop();
        StringBuilder b = new StringBuilder(1 << 20);
        b.Append("{\"drive\":").Append(Esc(root.Name)).Append(",\"label\":").Append(Esc(label ?? ""));
        b.Append(",\"total\":").Append(total).Append(",\"free\":").Append(free);
        b.Append(",\"files\":").Append(TotalFiles).Append(",\"dirs\":").Append(TotalDirs).Append(",\"denied\":").Append(TotalDenied);
        b.Append(",\"seconds\":").Append(((int)seconds).ToString());
        b.Append(",\"top\":[");
        for (int i = 0; i < Top.Count; i++)
        {
            if (i > 0) b.Append(',');
            b.Append('[').Append(Esc(Top[i].Key)).Append(',').Append(Top[i].Value).Append(']');
        }
        b.Append("],\"ext\":[");
        List<KeyValuePair<string, long[]>> ex = new List<KeyValuePair<string, long[]>>(Ext);
        ex.Sort(delegate(KeyValuePair<string, long[]> x, KeyValuePair<string, long[]> y) { return y.Value[0].CompareTo(x.Value[0]); });
        int lim = Math.Min(ex.Count, 60);
        for (int i = 0; i < lim; i++)
        {
            if (i > 0) b.Append(',');
            b.Append('[').Append(Esc(ex[i].Key.ToLowerInvariant())).Append(',').Append(ex[i].Value[0]).Append(',').Append(ex[i].Value[1]).Append(']');
        }
        b.Append("],\"tree\":");
        NodeJson(root, b);
        b.Append('}');
        return b.ToString();
    }
}

'@

$isAdmin = $false
try { $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}

Write-Host ''
Write-Host '  DISK HOG' -ForegroundColor Yellow
Write-Host '  Finds what is using your space. Looks only, never deletes.' -ForegroundColor DarkGray
if (-not $isAdmin) { Write-Host '  Tip: right-click the .bat and "Run as administrator" to see locked system folders too.' -ForegroundColor DarkGray }
Write-Host ''

$drives = @([IO.DriveInfo]::GetDrives() | Where-Object { $_.IsReady -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') })
if ($drives.Count -eq 0) { throw 'No drives found.' }

for ($i = 0; $i -lt $drives.Count; $i++) {
    $d = $drives[$i]
    $used = $d.TotalSize - $d.TotalFreeSpace
    $pct = [math]::Round(100 * $used / [math]::Max([double]1, [double]$d.TotalSize))
    $label = ''; try { $label = $d.VolumeLabel } catch {}
    $color = 'Gray'; if ($pct -ge 90) { $color = 'Red' } elseif ($pct -ge 75) { $color = 'Yellow' }
    Write-Host ('  [{0}] {1,-4} {2,-14} {3,10} free of {4,-10} ({5}% full)' -f ($i + 1), $d.Name.TrimEnd('\'), $label, (Format-Size $d.TotalFreeSpace), (Format-Size $d.TotalSize), $pct) -ForegroundColor $color
}
Write-Host ''
$pick = Read-Host '  Which drive? Type a number, or just press Enter to scan all'

$targets = @()
if ([string]::IsNullOrWhiteSpace($pick)) { $targets = $drives }
else {
    foreach ($p in ($pick -split '[ ,]+')) {
        $n = 0
        if ([int]::TryParse($p, [ref]$n) -and $n -ge 1 -and $n -le $drives.Count) { $targets += $drives[$n - 1] }
    }
    if ($targets.Count -eq 0) { throw "Didn't understand '$pick'." }
}

$parts = @()
foreach ($d in $targets) {
    Write-Host ''
    Write-Host ('  Scanning {0} ...' -f $d.Name) -ForegroundColor Cyan
    $label = ''; try { $label = $d.VolumeLabel } catch {}
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $scanner = New-Object DHScanner
    $root = $scanner.Scan($d.RootDirectory.FullName)
    $sw.Stop()
    $parts += $scanner.DriveJson($root, $label, $d.TotalSize, $d.TotalFreeSpace, $sw.Elapsed.TotalSeconds)
    Write-Host ('  Done: {0} found in {1:N0} files ({2:N0}s)' -f (Format-Size $root.Size), $scanner.TotalFiles, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
    $root = $null; $scanner = $null; [GC]::Collect()
}

$template = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Disk Hog Report</title>
<style>
:root{
  --bg:#f6f5f2; --panel:#ffffff; --ink:#1d1d1b; --muted:#6d6b66; --line:#e4e2dc;
  --bar:#d9d5cb; --hot:#d9480f; --warm:#e8913a; --cool:#3b7a8c; --ok:#2f7d4f; --free:#cfe5d6;
  --chip:#efece5;
}
@media (prefers-color-scheme: dark){
  :root{ --bg:#141413; --panel:#1d1d1b; --ink:#ecebe7; --muted:#9a978f; --line:#2f2e2b;
    --bar:#3a3833; --hot:#ff7a45; --warm:#f0a35a; --cool:#6fb3c6; --ok:#5fbf86; --free:#24402f; --chip:#2a2926; }
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:14px/1.45 "Segoe UI",system-ui,-apple-system,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:24px 16px 60px}
h1{font-size:22px;margin:0 0 2px;letter-spacing:-.01em}
h2{font-size:15px;margin:0 0 12px;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);font-weight:600}
.sub{color:var(--muted);margin-bottom:18px}
.tabs{display:flex;gap:8px;flex-wrap:wrap;margin:14px 0 18px}
.tab{border:1px solid var(--line);background:var(--panel);color:var(--ink);padding:8px 14px;border-radius:8px;cursor:pointer;font:inherit}
.tab.on{border-color:var(--ink);font-weight:600}
.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:18px;margin-bottom:16px}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
@media (max-width:800px){.grid{grid-template-columns:1fr}}
.usage{height:22px;border-radius:6px;background:var(--free);overflow:hidden;display:flex;margin:10px 0 8px}
.usage span{display:block;height:100%}
.legend{display:flex;gap:16px;flex-wrap:wrap;color:var(--muted);font-size:13px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:6px;vertical-align:-1px}
.big{font-size:28px;font-weight:700;letter-spacing:-.02em}
.crumbs{display:flex;flex-wrap:wrap;gap:4px;align-items:center;margin-bottom:12px;font-size:13px}
.crumbs a{color:var(--cool);cursor:pointer;text-decoration:none}
.crumbs a:hover{text-decoration:underline}
.crumbs .sep{color:var(--muted)}
.row{display:grid;grid-template-columns:minmax(0,1fr) 90px 60px;gap:10px;align-items:center;padding:6px 8px;border-radius:6px;position:relative}
.row.dir{cursor:pointer}
.row.dir:hover{background:var(--chip)}
.row .nm{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;position:relative;z-index:1}
.row .sz{text-align:right;font-variant-numeric:tabular-nums;font-weight:600;z-index:1}
.row .pc{text-align:right;color:var(--muted);font-variant-numeric:tabular-nums;font-size:12px;z-index:1}
.row .fill{position:absolute;left:0;top:3px;bottom:3px;border-radius:5px;background:var(--bar);opacity:.55;z-index:0}
.row.dir .fill{background:var(--cool);opacity:.18}
.row.file .fill{background:var(--warm);opacity:.22}
.ic{display:inline-block;width:18px;color:var(--muted)}
.note{font-size:12px;color:var(--muted);margin-top:10px}
.sus{border-left:3px solid var(--hot);padding:10px 12px;margin-bottom:10px;background:var(--chip);border-radius:0 8px 8px 0}
.sus.safe{border-color:var(--ok)}
.sus.careful{border-color:var(--warm)}
.sus .t{display:flex;justify-content:space-between;gap:10px;font-weight:600}
.sus .p{font-size:12px;color:var(--muted);word-break:break-all;margin:3px 0}
.sus .d{font-size:13px}
.tag{font-size:11px;padding:1px 7px;border-radius:10px;background:var(--panel);border:1px solid var(--line);margin-left:6px;font-weight:500;color:var(--muted)}
code{background:var(--chip);padding:1px 5px;border-radius:4px;font-size:12px}
table{width:100%;border-collapse:collapse}
td{padding:6px 6px;border-bottom:1px solid var(--line);vertical-align:top}
td.n{text-align:right;font-weight:600;white-space:nowrap;font-variant-numeric:tabular-nums}
td.p{word-break:break-all;font-size:13px}
button.copy{border:1px solid var(--line);background:var(--panel);color:var(--muted);border-radius:6px;font-size:11px;padding:2px 7px;cursor:pointer}
button.copy:hover{color:var(--ink)}
button.more{margin-top:10px;border:1px solid var(--line);background:var(--panel);color:var(--ink);border-radius:8px;padding:6px 12px;cursor:pointer;font:inherit}
.empty{color:var(--muted);padding:6px 8px}
</style>
</head>
<body>
<div class="wrap">
  <h1>Where did my space go?</h1>
  <div class="sub" id="meta"></div>
  <div class="tabs" id="tabs"></div>
  <div id="main"></div>
</div>
<script>
const DATA = __DATA__;
const GENERATED = "__WHEN__";

const $ = (s, el=document) => el.querySelector(s);
function fmt(b){
  if (b < 1024) return b + " B";
  const u = ["KB","MB","GB","TB"]; let i=-1;
  do { b /= 1024; i++; } while (b >= 1024 && i < u.length-1);
  return (b >= 100 ? b.toFixed(0) : b >= 10 ? b.toFixed(1) : b.toFixed(2)) + " " + u[i];
}
function pct(a,b){ return b ? (100*a/b) : 0; }
function esc(s){ return String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c])); }
function copy(text, btn){
  const done = () => { const o = btn.textContent; btn.textContent = "Copied"; setTimeout(()=>btn.textContent=o, 1200); };
  if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, () => fallback());
  else fallback();
  function fallback(){ const t=document.createElement("textarea"); t.value=text; document.body.appendChild(t); t.select(); try{document.execCommand("copy");}catch(e){} t.remove(); done(); }
}
document.addEventListener("click", e => { const b = e.target.closest("button.copy"); if (b) { e.stopPropagation(); copy(b.dataset.path, b); } });

// node = [name, size, files, denied, kids, bigFiles]
const N = {name:0,size:1,files:2,denied:3,kids:4,big:5};

// ---------- cleanup suspects ----------
const RULES = [
  {match:(n,p)=>/^\$recycle\.bin$/i.test(n), title:"Recycle Bin", level:"safe",
   tip:"Files you deleted but never emptied. Right-click the Recycle Bin on your desktop and choose Empty Recycle Bin."},
  {match:(n,p)=>/^windows\.old$/i.test(n), title:"Old Windows install (Windows.old)", level:"safe",
   tip:"Left behind by a Windows upgrade. Remove it with Disk Cleanup, then Clean up system files, then tick Previous Windows installation(s)."},
  {match:(n,p)=>/\\appdata\\local\\temp$/i.test(p) || /^.:\\windows\\temp$/i.test(p) || /\\windows\\temp$/i.test(p), title:"Temp files", level:"safe",
   tip:"Scratch files apps forgot to clean up. Press Win+R, type <code>%temp%</code>, select all and delete (skip anything in use)."},
  {match:(n,p)=>/\\windows\\softwaredistribution\\download$/i.test(p), title:"Windows Update download cache", level:"safe",
   tip:"Already-installed update packages. Disk Cleanup, then Clean up system files, then Windows Update Cleanup."},
  {match:(n,p)=>/\\(crashdumps|minidump)$/i.test(p) || /^memory\.dmp$/i.test(n), title:"Crash dumps", level:"safe",
   tip:"Debug snapshots from crashes. Safe to delete unless you're actively troubleshooting a crash."},
  {match:(n,p)=>/^(inetcache|cache|cache2|code cache|gpucache|shadercache|dxcache|glcache|nv_cache|d3dscache)$/i.test(n), title:"App / browser / GPU cache", level:"safe",
   tip:"Caches rebuild themselves. Clear browser cache from the browser's settings; GPU shader caches via Disk Cleanup (DirectX Shader Cache)."},
  {match:(n,p)=>/^(npm-cache|\.npm|pip|\.gradle|\.nuget|\.cargo|go-build|yarn)$/i.test(n) && /\\(appdata|users)\\/i.test(p), title:"Developer package cache", level:"safe",
   tip:"Downloaded packages kept for reuse. Commands like <code>npm cache clean --force</code> or <code>pip cache purge</code> clear them."},
  {match:(n,p)=>/^node_modules$/i.test(n), title:"node_modules", level:"safe",
   tip:"Installed JavaScript packages for a project. Delete for projects you're not using; <code>npm install</code> restores them."},
  {match:(n,p)=>/\\users\\[^\\]+\\downloads$/i.test(p), title:"Downloads folder", level:"careful",
   tip:"Usually installers and zips you already used. Sort by size and clear out what you don't need."},
  {match:(n,p)=>/\\users\\[^\\]+\\(videos|onedrive\\videos)$/i.test(p) || /\\videos\\captures$/i.test(p), title:"Videos / recordings", level:"careful",
   tip:"Screen recordings and clips (Xbox Game Bar, OBS) add up fast. Move keepers to an external drive."},
  {match:(n,p)=>/^steamapps$/i.test(n) || /\\epic games$/i.test(p) || /^(riot games|battle\.net|xboxgames|ea games)$/i.test(n), title:"Games", level:"careful",
   tip:"Uninstall games you don't play from the launcher itself (Steam, Epic, etc.) so it cleans up properly."},
  {match:(n,p)=>/\\appdata\\local\\roblox$/i.test(p), title:"Roblox data", level:"careful",
   tip:"Roblox Studio and player caches/logs. The logs and download folders inside can be cleared."},
  {match:(n,p)=>/\\appdata\\local\\(docker|packages\\canonicalgrouplimited[^\\]*)$/i.test(p) || /^ext4\.vhdx$/i.test(n), title:"Docker / WSL disk", level:"careful",
   tip:"Linux and Docker virtual disks only grow. Run <code>docker system prune</code>, then compact the .vhdx."},
  {match:(n,p)=>/\\programdata\\package cache$/i.test(p), title:"Installer package cache", level:"careful",
   tip:"Visual Studio and similar installers keep copies here. Don't delete by hand; it can break repairs and uninstalls."},
  {match:(n,p)=>/^hiberfil\.sys$/i.test(n), title:"Hibernation file", level:"careful",
   tip:"Sized like your RAM. If you never hibernate, run <code>powercfg /h off</code> in an admin terminal (also turns off Fast Startup)."},
  {match:(n,p)=>/^(pagefile|swapfile)\.sys$/i.test(n), title:"Page file", level:"leave",
   tip:"Windows virtual memory. Leave it alone unless you know what you're doing."},
  {match:(n,p)=>/^.:\\windows\\winsxs$/i.test(p), title:"WinSxS (Windows component store)", level:"leave",
   tip:"Never delete by hand. Its real size is smaller than shown (shared hard links). Admin terminal: <code>DISM /Online /Cleanup-Image /StartComponentCleanup</code>."},
];

function findSuspects(d){
  const hits = [];
  const root = d.tree;
  function walk(node, path, depth){
    const name = node[N.name];
    if (depth > 0) {
      for (const r of RULES) {
        if (r.match(name, path)) { hits.push({rule:r, path, size:node[N.size]}); return; }
      }
    }
    for (const f of node[N.big]) {
      const fp = path + "\\" + f[0];
      for (const r of RULES) if (r.match(f[0], fp)) { hits.push({rule:r, path:fp, size:f[1]}); break; }
    }
    for (const k of node[N.kids]) walk(k, path + "\\" + k[N.name], depth+1);
  }
  walk(root, root[N.name], 0);
  // also big disk-image style files anywhere
  for (const [p,s] of d.top) {
    if (/\.(iso|vhd|vhdx|vmdk|img)$/i.test(p) && !/\\ext4\.vhdx$/i.test(p) && !hits.some(h=>h.path===p))
      hits.push({rule:{title:"Disk image / virtual disk", level:"careful", tip:"ISO or virtual-machine disk. Delete if you no longer need that installer or VM."}, path:p, size:s});
  }
  const min = 200*1024*1024;
  return hits.filter(h=>h.size>=min).sort((a,b)=>b.size-a.size);
}

// ---------- render ----------
let cur = 0;
let navPath = [];

function render(){
  const d = DATA[cur];
  $("#meta").innerHTML = `Scanned ${esc(GENERATED)} · ${DATA.length} drive${DATA.length>1?"s":""}`;
  $("#tabs").innerHTML = DATA.length > 1 ? DATA.map((x,i)=>{
    const used = x.total - x.free;
    return `<button class="tab ${i===cur?"on":""}" data-i="${i}">${esc(x.drive)} ${x.label?esc(x.label):""} · ${Math.round(pct(used,x.total))}% full</button>`;
  }).join("") : "";
  document.querySelectorAll(".tab").forEach(b => b.onclick = () => { cur = +b.dataset.i; navPath = []; render(); });

  const used = d.total - d.free;
  const scanned = d.tree[N.size];
  const hidden = Math.max(0, used - scanned);
  const usedPct = pct(used, d.total);
  const sus = findSuspects(d);
  const reclaim = sus.filter(s=>s.rule.level==="safe").reduce((a,s)=>a+s.size,0);

  $("#main").innerHTML = `
  <div class="panel">
    <div style="display:flex;justify-content:space-between;flex-wrap:wrap;gap:12px;align-items:baseline">
      <div><div class="big">${fmt(d.free)} free</div><div class="sub" style="margin:0">of ${fmt(d.total)} on ${esc(d.drive)}${d.label?" ("+esc(d.label)+")":""}, ${usedPct.toFixed(0)}% full</div></div>
      <div style="text-align:right;color:var(--muted);font-size:13px">${d.files.toLocaleString()} files · ${d.dirs.toLocaleString()} folders · scanned in ${d.seconds}s</div>
    </div>
    <div class="usage">
      <span style="width:${pct(scanned,d.total)}%;background:var(--cool)"></span>
      <span style="width:${pct(hidden,d.total)}%;background:var(--bar)"></span>
    </div>
    <div class="legend">
      <span><i style="background:var(--cool)"></i>Files found: ${fmt(scanned)}</span>
      <span><i style="background:var(--bar)"></i>Couldn't see: ${fmt(hidden)}</span>
      <span><i style="background:var(--free)"></i>Free: ${fmt(d.free)}</span>
    </div>
    ${d.denied ? `<div class="note">${d.denied.toLocaleString()} folders were locked. For the full picture, right-click <b>Run Disk Hog.bat</b> and choose <b>Run as administrator</b>. System restore points and shadow copies also land in "couldn't see".</div>` : ""}
  </div>

  <div class="panel">
    <h2>Browse folders</h2>
    <div class="crumbs" id="crumbs"></div>
    <div id="list"></div>
    <div class="note">Click a folder to open it. Folders under 5 MB and files under 25 MB are rolled into "smaller items".</div>
  </div>

  <div class="grid">
    <div class="panel">
      <h2>Cleanup suspects</h2>
      ${sus.length ? `<div class="note" style="margin:-6px 0 12px">About <b>${fmt(reclaim)}</b> sits in places that are usually safe to clear.</div>` : ""}
      <div id="sus"></div>
    </div>
    <div class="panel">
      <h2>Space by file type</h2>
      <div id="ext"></div>
    </div>
  </div>

  <div class="panel">
    <h2>Biggest files</h2>
    <table id="top"></table>
    <button class="more" id="more">Show more</button>
  </div>`;

  renderBrowser();
  renderSuspects(sus);
  renderExt(d);
  renderTop(d, 25);
}

function nodeAt(d){
  let n = d.tree;
  for (const i of navPath) n = n[N.kids][i];
  return n;
}
function pathOf(d){
  let n = d.tree, p = n[N.name];
  for (const i of navPath) { n = n[N.kids][i]; p += "\\" + n[N.name]; }
  return p;
}

function renderBrowser(){
  const d = DATA[cur];
  const node = nodeAt(d);
  const path = pathOf(d);

  // breadcrumbs
  let crumbs = [], n = d.tree;
  crumbs.push(`<a data-depth="0">${esc(n[N.name]||"\\")}\\</a>`);
  navPath.forEach((i,k) => { n = n[N.kids][i]; crumbs.push(`<span class="sep">›</span><a data-depth="${k+1}">${esc(n[N.name])}</a>`); });
  crumbs.push(`<span style="margin-left:auto"></span><button class="copy" data-path="${esc(path)}">Copy path</button>`);
  $("#crumbs").innerHTML = crumbs.join("");
  document.querySelectorAll("#crumbs a").forEach(a => a.onclick = () => { navPath = navPath.slice(0, +a.dataset.depth); renderBrowser(); });

  const total = node[N.size] || 1;
  const items = [];
  node[N.kids].forEach((k,i) => items.push({type:"dir", name:k[N.name], size:k[N.size], idx:i, files:k[N.files], locked:k[N.denied]}));
  node[N.big].forEach(f => items.push({type:"file", name:f[0], size:f[1]}));
  items.sort((a,b)=>b.size-a.size);
  const shown = items.reduce((a,x)=>a+x.size,0);
  const rest = node[N.size] - shown;

  const max = items.length ? items[0].size : 1;
  let html = items.map(x => `
    <div class="row ${x.type}" ${x.type==="dir"?`data-idx="${x.idx}"`:""} title="${esc(x.name)}">
      <div class="fill" style="width:${pct(x.size,max)}%"></div>
      <div class="nm"><span class="ic">${x.type==="dir"?"▸":"·"}</span>${esc(x.name)}${x.type==="dir"&&x.files?` <span style="color:var(--muted);font-size:12px">${x.files.toLocaleString()} files</span>`:""}${x.locked?` <span class="tag">some locked</span>`:""}</div>
      <div class="sz">${fmt(x.size)}</div>
      <div class="pc">${pct(x.size,total).toFixed(1)}%</div>
    </div>`).join("");
  if (rest > 0) html += `
    <div class="row"><div class="fill" style="width:${pct(rest,max)}%"></div>
      <div class="nm"><span class="ic"></span><span style="color:var(--muted)">smaller items</span></div>
      <div class="sz">${fmt(rest)}</div><div class="pc">${pct(rest,total).toFixed(1)}%</div></div>`;
  if (!items.length && rest <= 0) html = `<div class="empty">Empty${node[N.denied]?" (or locked)":""}.</div>`;
  $("#list").innerHTML = html;
  document.querySelectorAll("#list .row.dir").forEach(r => r.onclick = () => { navPath.push(+r.dataset.idx); renderBrowser(); });
}

function renderSuspects(sus){
  const lvl = {safe:"usually safe", careful:"review first", leave:"leave alone"};
  $("#sus").innerHTML = sus.length ? sus.slice(0,20).map(s => `
    <div class="sus ${s.rule.level}">
      <div class="t"><span>${esc(s.rule.title)}<span class="tag">${lvl[s.rule.level]}</span></span><span>${fmt(s.size)}</span></div>
      <div class="p">${esc(s.path)} <button class="copy" data-path="${esc(s.path)}">Copy</button></div>
      <div class="d">${s.rule.tip}</div>
    </div>`).join("") : `<div class="empty">Nothing obvious over 200 MB. Check the folder browser and biggest files.</div>`;
}

function renderExt(d){
  const tot = d.tree[N.size] || 1;
  const rows = d.ext.slice(0,15);
  const max = rows.length ? rows[0][1] : 1;
  $("#ext").innerHTML = rows.map(([e,s,c]) => `
    <div class="row"><div class="fill" style="width:${pct(s,max)}%"></div>
      <div class="nm">${esc(e)} <span style="color:var(--muted);font-size:12px">${c.toLocaleString()} file${c===1?"":"s"}</span></div>
      <div class="sz">${fmt(s)}</div><div class="pc">${pct(s,tot).toFixed(1)}%</div></div>`).join("");
}

function renderTop(d, count){
  const rows = d.top.slice(0, count);
  $("#top").innerHTML = rows.map(([p,s]) => `<tr><td class="n">${fmt(s)}</td><td class="p">${esc(p)}</td><td><button class="copy" data-path="${esc(p)}">Copy</button></td></tr>`).join("");
  const more = $("#more");
  if (count >= d.top.length) more.style.display = "none";
  else more.onclick = () => renderTop(d, count + 50);
}

render();
</script>
</body>
</html>

'@

$when = (Get-Date).ToString('MMM d, yyyy h:mm tt')
$html = $template.Replace('__DATA__', '[' + ($parts -join ',') + ']').Replace('__WHEN__', $when)

$name = 'DiskHog Report ' + (Get-Date -Format 'yyyy-MM-dd HHmm') + '.html'
$out = Join-Path $PSScriptRoot $name
try { [IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding $false)) }
catch { $out = Join-Path $env:TEMP $name; [IO.File]::WriteAllText($out, $html, (New-Object Text.UTF8Encoding $false)) }

Write-Host ''
Write-Host "  Report saved: $out" -ForegroundColor Green
Write-Host '  Opening it in your browser...'
Start-Process $out
Start-Sleep -Seconds 2
}
catch {
    Write-Host ''
    Write-Host ('  Something went wrong: ' + $_.Exception.Message) -ForegroundColor Red
    Read-Host '  Press Enter to close'
}
