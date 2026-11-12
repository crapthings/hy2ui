# Hy2UI design notes

> 当前核心架构：官方 CLI 二进制（rc.6），不编译或 patch Rust。Network Extension、进程分流、核心流量统计与 RTT 测试入口已停用；规则仅用于系统自动 PAC。运行边界以 docs/DEVELOPMENT.md 为准。


`App/AppTheme.swift` and `App/AppIcon.swift` define the shared visual system. Keep configuration behavior and navigation separate from appearance.

## Surfaces and typography

- Use the adaptive warm-gray canvas, white cards and muted green accent from `AppTheme`.
- Page titles are 26pt semibold, dialog titles 20pt and dashboard card titles 18pt. Section titles are 14pt semibold, body text 13pt and secondary text 12pt. Secondary text must retain at least 4.5:1 contrast against both the paper and canvas surfaces.
- Page padding is 24pt. Card padding and grid gaps are 20pt. Cards have 20pt corners and a light shadow, without a decorative outline.
- Buttons are at least 36pt high, with 16pt horizontal padding and 8pt corners. Fields use the same corner token and a focus-only accent outline.
- Use 32pt hit areas for compact icon actions, with hover and keyboard-focus feedback. Center concise icon-and-title empty states within cards. Clip scroll content before adding the card shadow. Lists use spacing and selection fills instead of static outlines or separator lines; retain focus rings and functional selection indicators. Preserve dark-mode colors, keyboard operation and accessibility labels. Do not use color alone for rule or installation state.

## Navigation and search

The floating icon rail contains Overview, Processes, Policies and Rules, with Logs and Settings below. Selection uses a contrasting circular background. Icons come from the pinned local IconMCP Outline assets; native control indicators remain native.

The shared header owns each page's title and short subtitle. Do not repeat page titles inside the content. One capsule search component serves policies, processes and rules; each page retains its own query. Search fields share a stable 300pt width and include a clear action and search button. Clearing keeps input focus; Escape clears the query before leaving the field.

## Overview

Use the full available width. On wide windows, show four compact metric cards above two rows of mixed-size cards: network trends span two columns, with capture and FINAL cards beside them; the server preview spans two columns, with rule and log summaries beside it. Narrow windows reflow to two columns.

Only plot actual core samples. Use tabular numbers, binary byte units and an honest empty state when measurements are unavailable. Dashboard totals and system process counters have different scopes and must not be added together.

## Processes and rules

The process list has PID, name/path, rule, upload/download and sent/received columns. Paired numeric headings stack in the same order as their measurements; each remains individually sortable, with reserved arrow space to prevent text movement. Clicking a column cycles through both sort directions and default name order. Keep row identities and selection stable during sampling. Selected process details use separate information, path and transfer cards, with a 20pt gutter and no split-view divider.

Rules use one table with enabled, number, type, value, policy, localized hit count, comment and a row delete action, ending with a nondeletable FINAL fallback row without a toggle or matching value. Keep row numbers but leave their column heading blank. The add action sits above the table at the trailing edge, separated by the standard 20pt section gap, and opens the Standard Rule sheet with a type picker, value/helper, policy and comment; double-click edits. Disabled rule text is muted while its checkbox remains the explicit state indicator. Comments participate in header search. A query filters FINAL as well as standard rules, and an empty match has a clear state. Selection is pruned against visible rows before delete actions. The table has a fixed 44pt header with bounded-height placeholders; rows start directly below it with no automatic list content margins. The table scrolls horizontally in narrow windows while its add and pending-change toolbar stays fixed above it. Native list selection supplies single-click highlights and the native primary action opens the editor on double-click. The hit-count heading is “命中” in Chinese and “Used” in English; its value initially displays 0 while backend hit counters are unavailable, and empty comments remain blank. Preserve the core's matching semantics and do not imply configurable drag ordering. Disabled rules are excluded from runtime configuration; comments alone never require reconnecting.

## Controls and copy

Server editing places connection and security cards side by side on wide windows and stacks them on narrow windows. Pair host and port fields, keep deletion separate from saving, and show unsaved state beside Save without a routine saved banner. Policy measurement progress appears beside each active endpoint. Log controls share the card footer. Background maintenance states must distinguish checking, missing, current, update and repair rather than treating every installed component as ready.

Capture switches belong to Overview, with menu-bar shortcuts. Settings contains transport parameters and background-service maintenance. Do not repeat capture controls or onboarding links across pages.

Place field labels and necessary helper text beside their inputs. Keep validation errors, pending-change status, recovery actions and deletion confirmations. Avoid explanatory banners, repeated section introductions and routine save messages. Chinese and English share the same structure.

FINAL menus place DIRECT first, followed by a separator and saved servers. DIRECT is persisted independently of the last selected server. A live switch applies immediately and restores the previous policy on failure; choosing the same saved server again must exit DIRECT. Dashboard and policy-selection indicators reflect the actual FINAL choice.
