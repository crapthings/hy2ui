# Hy2UI design notes

Use native desktop behavior, clear information hierarchy, and enough space to keep the interface calm.

## Color

`App/AppTheme.swift` is the source of truth for design tokens. Use a paper-white canvas, near-black text, and blue `#024AD8` for the main action. Quiet gray surfaces define groups. Green and red communicate installation status. Dark mode has its own adaptive palette. Keep native glass in the sidebar only, and respect Reduce Transparency.

## Layout

- Page titles: 24pt. Section titles: 14pt semibold. Body: 13pt. Secondary text: 12pt.
- Page padding: 32pt. Card padding and section gaps: 24pt. Field gaps: 20pt.
- Place section headings outside their cards. Stack each field label, input, and necessary help text vertically.
- Cards have no decorative border and use 10pt corners. Inputs are 36pt tall with 6pt corners and a focus-only blue ring.
- Buttons are 36pt tall with 16pt horizontal padding and 4pt corners. Preserve native menu keyboard and accessibility behavior.
- Select controls fill the input column. Keep the selected value on the left and a single chevron on the right. Hide repeated labels inside the menu.

## Navigation and status

- Show up to three servers in the sidebar. Put the add button beside the Servers heading. More opens the management list.
- Place capture menus at the trailing edge of the window toolbar. Each has a status dot, name, and chevron, with 32pt height, 12pt horizontal padding, and 4pt corners.
- Green means active, amber means waiting to connect, and gray means off. Keep the menu text neutral; only the status dot uses semantic color.
- In Settings, installation status is plain red Not Installed or green Installed text, without a dot or background.

## Overview and activity

Keep connection controls at the top of Overview. Use a two-column grid of quiet cards for upload, download, today, and this month. Display active QUIC RTT beside the selected server. Use tabular numbers and binary byte units.

Detailed system process activity has a separate navigation page. State its scope clearly and keep its counters separate from connection totals. Show unavailable data honestly rather than generating placeholder measurements.

## Copy

Keep labels short and useful. Avoid repeated headings, permanent long instructions, and routine save messages. Retain validation errors, recovery actions, and deletion confirmations. Chinese and English share the same layout and behavior.
