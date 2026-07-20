#!/usr/bin/env bash
# Print PIA's current region list: the values PIA_LOC / LOC accept.
# A browsable snapshot lives in docs/regions.md; this is the live view.
#
#   ./scripts/list-regions.sh            # all regions
#   ./scripts/list-regions.sh au         # filter (case-insensitive, id/name/country)
set -euo pipefail

filter="${1:-}"

curl -sf "https://serverlist.piaservers.net/vpninfo/servers/v6" | head -1 | python3 -c "
import json, sys
regions = json.load(sys.stdin)['regions']
flt = '''$filter'''.lower()
rows = sorted(
    ((r['id'], r['name'], r['country'], 'yes' if r['port_forward'] else 'no', 'geo' if r['geo'] else '')
     for r in regions if not r.get('offline')),
    key=lambda t: (t[2], t[1]),
)
if flt:
    rows = [t for t in rows if flt in t[0].lower() or flt in t[1].lower() or flt in t[2].lower()]
print(f'{\"PIA_LOC\":22} {\"REGION\":34} {\"CC\":3} {\"PORTFWD\":8} GEO')
for t in rows:
    print(f'{t[0]:22} {t[1]:34} {t[2]:3} {t[3]:8} {t[4]}')
print(f'\n{len(rows)} regions')
"
