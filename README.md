# SnafflerCrappler, a better way to parse your Snaffle output into a 🔥 html report
## Usage
```
C:\Users\User\Documents\GitHub\SnafflerCrappler\snafflerParser.ps1
 ____               __  __ _             ____
/ ___| _ __   __ _ / _|/ _| | ___ _ __  |  _ \ __ _ _ __ ___  ___ _ __
\___ \|  _ \ / _  | |_| |_| |/ _ \ '__| | |_) / _  | '__/ __|/ _ \ '__|
 ___) | | | | (_| |  _|  _| |  __/ |    |  __/ (_| | |  \__ \  __/ |
|____/|_| |_|\__,_|_| |_| |_|\___|_|    |_|   \__,_|_|  |___/\___|_|


USAGE
  .\snafflerParser.ps1 -in <file> [options]
  .\snafflerParser.ps1 -ins <file1>,<file2> [options]
  .\snafflerParser.ps1 -indir <folder> [options]

INPUT
  -in     <path>      Single Snaffler log file (default: snafflerout.txt)
  -ins    <p1>,<p2>   Comma-separated list of log files (deduplicates across files)
  -indir  <folder>    Parse all .log/.txt files in a directory

OUTPUT
  -outformat <fmt>    Output format: default | all | csv | txt | json | html
                        default = CSV + TXT + HTML
                        all     = CSV + TXT + HTML + JSON
  -sort   <field>     Sort by: modified (default) | keyword | rule | unc
  -split              Also write per-severity files (black/red/yellow/green)

SCORING
  -domain <name>      Domain keyword (e.g. CORP) for boosted credential scoring:
                        Score 1 = real-looking credential value
                        Score 2 = + domain context (@CORP, CORP\user, UNC path)
                        Score 3 = + service account (svc-, sa-, CORP\svc*)

INTERACTIVE
  -gridview           Show results in PowerShell GridView after parsing
  -gridviewload       Load a previously saved GridView CSV
  -gridin <path>      GridView CSV to load (default: snafflerout.txt_loot_gridview.csv)
  -pte                Export shares as Explorer++ bookmarks
  -snaffel            Run Snaffler.exe first, then parse output

EXAMPLES
  .\snafflerParser.ps1 -in snaffler.log
  .\snafflerParser.ps1 -in snaffler.log -domain CORP
  .\snafflerParser.ps1 -ins scan1.log,scan2.log -domain CONTOSO -outformat all
  .\snafflerParser.ps1 -indir C:\logs\snaffler -domain CORP -split
  .\snafflerParser.ps1 -in snaffler.log -sort unc -outformat csv
```
# Report example
<img width="953" height="500" alt="image" src="https://github.com/user-attachments/assets/3fe5ce7c-ac27-4bff-9fa5-64d4046ec7d3" />
