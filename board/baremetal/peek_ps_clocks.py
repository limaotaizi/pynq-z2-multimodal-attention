import re
from pathlib import Path
import zipfile

z = zipfile.ZipFile(str(Path(__file__).resolve().parent / 'attn4_e4.xsa'))
hwh = [n for n in z.namelist() if n.endswith('.hwh')][0]
txt = z.read(hwh).decode('utf-8', 'replace')
print('hwh entry:', hwh, len(txt), 'chars')
print()

for m in re.finditer(r'<PARAMETER[^>]*NAME="([^"]*(?:FCLK|CPU_CLK|PLL)[^"]*)"[^>]*VALUE="([^"]*)"', txt):
    print(f'  {m.group(1):45s} = {m.group(2)}')

print()
for m in re.finditer(r'NAME="(PS7_[A-Z0-9_]+)"\s+VALUE="([^"]*)"', txt):
    n, v = m.group(1), m.group(2)
    if 'FCLK' in n and 'FREQ' in n:
        print(f'  {n:45s} = {v}')
