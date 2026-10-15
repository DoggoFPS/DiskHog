DiskHog

Clean your space. Find out what's filling up your Windows drives, in about a minute.

DiskHog scans your drives and opens a report in your browser showing which folders and files are using the most space, plus the usual culprits you can safely clean up.

Read-only. DiskHog never deletes, moves, or changes your files, and never connects to the internet. It only reads file sizes and writes one report file.

How to use
Click Code → Download ZIP and unzip it anywhere (like your Desktop).
Double-click Run Disk Hog.bat.
Pick a drive by number, or press Enter to scan all of them.
The report opens in your browser when it's done.

Tip: Right-click Run Disk Hog.bat → Run as administrator to see inside locked system folders too.

"Windows protected your PC" warning? That's SmartScreen. It appears for any unsigned script downloaded from the internet. Click More info → Run anyway. You can read the whole script in DiskHog.ps1 first if you want to check it.

What the report shows
Browse folders: a clickable breakdown of folders, biggest first. Drill down until you find the hog.
Cleanup suspects: spots common space wasters (Recycle Bin, Temp, Windows.old, Windows Update cache, Downloads, game libraries, Docker/WSL disks, node_modules, the hibernation file, and more). Each one is labeled usually safe, review first, or leave alone, with how to clean it the right way.
Biggest files on the drive.
Space by file type, like how much is videos vs. ISOs vs. everything else.
Copy path buttons. Paste into File Explorer's address bar to jump straight there.
Requirements
Windows 10 or 11
Nothing to install. It uses the PowerShell that comes with Windows.
Privacy

The report is saved next to the app as DiskHog Report <date>.html. It contains your file paths and Windows username, so don't share or upload it unless you mean to. Nothing is ever sent anywhere.

How it works

Run Disk Hog.bat launches DiskHog.ps1. The script compiles a small C# scanner on the fly for speed, walks the drive (skipping junctions/symlinks so nothing is counted twice), and fills a self-contained HTML report with the results.

License

MIT. See LICENSE.
