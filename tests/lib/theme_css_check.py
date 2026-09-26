"""
tests/lib/theme_css_check.py — reads the REAL app/styles/main.css and reports
facts about the v1.1.0 Aurora Glass theme, one KEY=VALUE per line.

It answers questions a browser would, without a browser:
  * does each of the three palettes define the tokens the owner fixed, at the
    values the owner fixed;
  * does --text-muted reach 4.5:1 against --bg-card in each palette (WCAG
    relative luminance, computed here, not asserted from a comment);
  * is any colour literal left outside the token blocks (the classification
    banner default is the one allowed exception);
  * are the colour-blind glyph cues present.

Usage: python theme_css_check.py <repo-root>
"""
import os
import re
import sys

root = sys.argv[1]
css = open(os.path.join(root, 'app', 'styles', 'main.css'), encoding='utf-8').read()


def block(selector):
    m = re.search(r'(?m)^' + re.escape(selector) + r'\s*\{(.*?)^\}', css, re.S)
    return m.group(1) if m else ''


def tokens(text):
    return {k: v.strip() for k, v in re.findall(r'(--[a-z0-9-]+)\s*:\s*([^;]+);', text)}


def lum(hexv):
    h = hexv.lstrip('#')
    if len(h) != 6:
        return None
    rgb = [int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in rgb]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a, b):
    la, lb = lum(a), lum(b)
    if la is None or lb is None:
        return 0.0
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


palettes = {'dark': tokens(block(':root')),
            'light': tokens(block('.light-mode')),
            'cb': tokens(block('.cb-mode'))}

# The owner's token map, 2026-09-26. Name in this stylesheet -> value.
WANT = {
    'dark': {'--bg-primary': '#101327', '--bg-card': '#1b2140', '--bg-secondary': '#252d50',
             '--border-color': '#3a4168', '--text-primary': '#f0f1ff', '--text-secondary': '#b0b5d1',
             '--accent': '#ac9aff', '--accent-cyan': '#7fd6e8', '--accent-green': '#80d4b4',
             '--accent-amber': '#e9c875', '--accent-red': '#ff989e', '--accent-purple': '#c2a4ff'},
    'light': {'--bg-primary': '#f1f2fd', '--bg-card': '#ffffff', '--bg-secondary': '#e6e9fb',
              '--border-color': '#c9cdeb', '--text-primary': '#242744', '--text-secondary': '#59617f',
              '--accent': '#6644c0', '--accent-green': '#147657', '--accent-amber': '#88600b',
              '--accent-red': '#b7354e', '--accent-purple': '#7b3bb8'},
    'cb': {'--bg-primary': '#0c111b', '--bg-card': '#172130', '--bg-secondary': '#202d3e',
           '--border-color': '#8393aa', '--text-primary': '#f4f7fc', '--text-secondary': '#cad3e1',
           '--accent': '#70c9f0', '--accent-green': '#8ed6c2', '--accent-amber': '#f0e442',
           '--accent-red': '#ffb58a'},
}

for mode, want in WANT.items():
    got = palettes[mode]
    wrong = ['%s=%s(want %s)' % (k, got.get(k, 'MISSING'), v)
             for k, v in want.items() if got.get(k, '').lower() != v]
    print('palette.%s=%s' % (mode, 'OK' if not wrong else 'WRONG ' + ' '.join(wrong)))
    ratio = contrast(got.get('--text-muted', ''), got.get('--bg-card', ''))
    print('muted_contrast.%s=%.2f' % (mode, ratio))

# Colour literals outside the token blocks. Strip the three palette blocks and
# the body-level derived-token blocks, then look for #hex and rgb()/rgba().
rest = css
for sel in (':root', '.light-mode', '.cb-mode', 'body.light-mode', 'body.cb-mode'):
    rest = re.sub(r'(?m)^' + re.escape(sel) + r'\s*\{.*?^\}', '', rest, flags=re.S)
rest = re.sub(r'(?ms)^body \{\n  --bg-panel.*?^\}', '', rest)
rest = re.sub(r'/\*.*?\*/', '', rest, flags=re.S)
lits = []
for ln in rest.splitlines():
    for m in re.finditer(r'#[0-9a-fA-F]{3,8}\b|rgba?\(', ln):
        lits.append(ln.strip()[:60])
banner = [l for l in lits if l.startswith('background: #22c55e') or l.startswith('color: #fff')]
others = [l for l in lits if l not in banner]
print('literals_outside_tokens=%d' % len(others))
for l in others[:5]:
    print('literal=%s' % l)
print('banner_default_literals=%d' % len(banner))

# The derived tokens the idle-warning card uses, and that it no longer carries
# literal fallbacks for.
print('bg_panel_defined=%s' % ('--bg-panel:' in css))
print('border_token_defined=%s' % bool(re.search(r'(?m)^\s*--border:\s', css)))
idle = re.search(r'\.idle-warn-card \{([^}]*)\}', css)
print('idle_card_fallback_literal=%s' % bool(idle and re.search(r'var\(--[a-z-]+,\s*#', idle.group(1))))

# Colour-blind cues: every status class carries a glyph in .cb-mode.
cues = {
    'bdg-ok': r'\.cb-mode \.bdg-ok::before\s*\{\s*content:\'\\2713\'',
    'bdg-warn': r'\.cb-mode \.bdg-warn::before\s*\{\s*content:\'!\'',
    'sub-ok': r'\.cb-mode \.stat-card \.sub\.ok::before\s*\{\s*content:\'\\2713',
    'sub-warn': r'\.cb-mode \.stat-card \.sub\.warn::before\s*\{\s*content:\'!',
    'sub-err': r'\.cb-mode \.stat-card \.sub\.err::before\s*\{\s*content:\'\\2715',
    'lag-tag': r'\.cb-mode \.lag-tag::before\s*\{\s*content:\'\\2715',
    'lag-hi': r'\.cb-mode \.lag-hi::before\s*\{\s*content:\'!',
}
missing = [k for k, rx in cues.items() if not re.search(rx, css)]
print('cb_cues=%s' % ('OK' if not missing else 'MISSING ' + ','.join(missing)))
# CB is solid: no glass gradient and no aurora field.
print('cb_solid=%s' % (palettes['cb'].get('--aurora-field') == 'none'
                       and bool(re.search(r'body\.cb-mode \{[^}]*--surface-glass:\s*var\(--bg-card\)', css))))
# Owner rule: body text and control metrics unchanged.
body = re.search(r'(?m)^body \{\n  font-family[^}]*\}', css)
print('body_font_size=%s' % (re.search(r'font-size:\s*([^;]+);', body.group(0)).group(1) if body else 'MISSING'))
print('radius=%s' % palettes['dark'].get('--radius', 'MISSING'))
