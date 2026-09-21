#!/usr/bin/env python3
"""Original small line icons, kept as SVG vectors in the asset catalog."""
import json
from pathlib import Path
root=Path(__file__).resolve().parents[1]/'CodexM/Resources/Assets.xcassets'
paths={
'NavQuit':'<path d="M12 3v9M6.3 5.8a8 8 0 1 0 11.4 0"/>',
'NavHandoff':'<path d="M4 8h16m-4-4 4 4-4 4M20 16H4m4-4-4 4 4 4"/>',
'NavAdd':'<path d="M12 4v16M4 12h16"/>',
'NavAccounts':'<circle cx="12" cy="8" r="4"/><path d="M4 21v-2a8 8 0 0 1 16 0v2Z"/>',
'NavSettings':'<path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2" fill="white"/><circle cx="15" cy="12" r="2" fill="white"/><circle cx="9" cy="18" r="2" fill="white"/>',

'ActionLaunch':'<path d="M8 5.5 18 12 8 18.5Z"/>',
'ActionEdit':'<path d="m14.5 5.5 4 4M4 20l4.5-1 11-11a2.83 2.83 0 0 0-4-4l-11 11Z"/>',
'ActionDelete':'<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 10v7M14 10v7"/>',
'ActionFocus':'<path d="M9 4H4v5M15 4h5v5M4 15v5h5M20 15v5h-5"/><circle cx="12" cy="12" r="3"/>',
'ActionRestart':'<path d="M19 9a7.5 7.5 0 1 0 .1 6M19 4v5h-5"/>',
'ActionStop':'<rect x="6" y="6" width="12" height="12" rx="2"/>',
'ActionNewWindow':'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 8h18M9 14h6M12 11v6"/>',
'ActionWindows':'<rect x="7" y="7" width="14" height="13" rx="2"/><path d="M17 7V4H3v12h4"/>',
'ActionReturn':'<path d="m9 5-5 5 5 5M4 10h10a5 5 0 0 1 0 10"/>',
}
for name,shape in paths.items():
    directory=root/(name+'.imageset');directory.mkdir(parents=True,exist_ok=True)
    svg=f'<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="#000" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round">{shape}</svg>\n'
    (directory/(name+'.svg')).write_text(svg)
    (directory/'Contents.json').write_text(json.dumps({'images':[{'filename':name+'.svg','idiom':'universal'}],'info':{'author':'CodexM','version':1},'properties':{'preserves-vector-representation':True,'template-rendering-intent':'template'}},indent=2)+'\n')
print(f'{len(paths)} original SVG action icons generated')
