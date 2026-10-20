#!/usr/bin/env python3
"""Render docs/network-diagram.dot to SVG and inject the docs' theme.

Graphviz cannot emit CSS, so the palette lives here: node classes come from
the .dot (`class="kube"` etc.) and this script injects a <style> block that
matches argo/docs/network-inventory.html, light and dark.

Usage (from the repo root):
    nix shell nixpkgs#graphviz -c dot -Tsvg docs/network-diagram.dot \
        | ./scripts/render-network-diagram.py > docs/network-diagram.svg
"""
import re
import sys

STYLE = """
<style type="text/css">
  text {
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    fill: #1d1d1f;
  }
  .edge path, .edge polygon { stroke: #666b70; fill: #666b70; }
  .edge.wifi path { stroke: #8a8f94; stroke-dasharray: 2,4; fill: none; }
  .edge.vip path { stroke: #9a5800; }
  #graph0 > polygon { fill: transparent; stroke: none; }
  .cluster > polygon { fill: transparent; stroke: #d9d6cf; }
  .node.internet ellipse { fill: #eceff1; stroke: #5f6368; stroke-width: 1.6; }
  .node.net > polygon, .node.net > path { fill: #e8eefb; stroke: #2457c5; stroke-width: 1.6; }
  .node.srv > polygon, .node.srv > path { fill: #ede8fa; stroke: #5b3fb0; stroke-width: 1.4; }
  .node.kube > polygon, .node.kube > path { fill: #e2f2e9; stroke: #1f7a4d; stroke-width: 1.4; }
  .node.cli > polygon, .node.cli > path { fill: #eef0f1; stroke: #8a8f94; stroke-width: 1.2; }
  .node.cam > polygon, .node.cam > path { fill: #fbe3e3; stroke: #b3261e; stroke-width: 1.4; }
  .node.ap > polygon, .node.ap > path { fill: #f0e9e4; stroke: #7a5c48; stroke-width: 1.4; }
  .node.vip > polygon, .node.vip > path { fill: #faedda; stroke: #9a5800; stroke-width: 1.4; }
  @media (prefers-color-scheme: dark) {
    text { fill: #e6e6e3; }
    .cluster > polygon { stroke: #34363b; }
    .edge path, .edge polygon { stroke: #a3a3a0; fill: #a3a3a0; }
    .edge.wifi path { stroke: #7d8288; }
    .edge.vip path { stroke: #e0a34a; }
    .edge.vip polygon { stroke: #e0a34a; fill: #e0a34a; }
    .node.internet ellipse { fill: #23262b; stroke: #a3a3a0; }
    .node.net > polygon, .node.net > path { fill: #1b2540; stroke: #7aa2ff; }
    .node.srv > polygon, .node.srv > path { fill: #241d3a; stroke: #b49cff; }
    .node.kube > polygon, .node.kube > path { fill: #14291f; stroke: #5cc28e; }
    .node.cli > polygon, .node.cli > path { fill: #23262b; stroke: #8f9398; }
    .node.cam > polygon, .node.cam > path { fill: #33201f; stroke: #f2766d; }
    .node.ap > polygon, .node.ap > path { fill: #2b2320; stroke: #c9a58c; }
    .node.vip > polygon, .node.vip > path { fill: #2e2416; stroke: #e0a34a; }
  }
</style>
"""


def main() -> int:
    svg = sys.stdin.read()
    if "<svg" not in svg:
        print("not an SVG on stdin", file=sys.stderr)
        return 1
    # theme block, right after the root element
    svg = re.sub(r"(<svg[^>]*>)", lambda m: m.group(1) + STYLE, svg, count=1)
    sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
