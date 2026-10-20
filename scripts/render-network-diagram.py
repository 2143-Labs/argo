#!/usr/bin/env python3
"""Render docs/network-diagram.dot to SVG, themed to match the docs.

Graphviz cannot emit CSS, so the palette lives here. Node categories come
from the .dot (`class="kube"` etc.); this script adds a <style> block using
the same hexes as docs/network-inventory.html, light and dark.

Modes:
  (default)   standalone SVG on stdout — the selectors are global
  --inline    an SVG *fragment* whose CSS is scoped under #expanded-diagram,
              safe to paste into a page
  --embed F   same as --inline, but rewrite the block between the
              `diagram:begin` / `diagram:end` markers in file F

Usage, from the repo root:
    nix shell nixpkgs#graphviz -c dot -Tsvg docs/network-diagram.dot \
        | ./scripts/render-network-diagram.py --embed docs/network-inventory.html
"""
import argparse
import re
import sys

CSS = """
  text {
    font-family: system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    fill: #1d1d1f;
  }
  #graph0 > polygon {
    fill: transparent;
    stroke: none;
  }
  .cluster > polygon {
    fill: transparent;
    stroke: #d9d6cf;
  }
  .edge path, .edge polygon {
    stroke: #666b70;
    fill: #666b70;
  }
  .edge.wifi path {
    stroke: #8a8f94;
    stroke-dasharray: 2,4;
    fill: none;
  }
  .edge.vip path {
    stroke: #9a5800;
  }
  .edge.vip polygon {
    stroke: #9a5800;
    fill: #9a5800;
  }
  .node.internet ellipse {
    fill: #eceff1;
    stroke: #5f6368;
    stroke-width: 1.6;
  }
  .node.net > polygon, .node.net > path {
    fill: #e8eefb;
    stroke: #2457c5;
    stroke-width: 1.6;
  }
  .node.srv > polygon, .node.srv > path {
    fill: #ede8fa;
    stroke: #5b3fb0;
    stroke-width: 1.4;
  }
  .node.kube > polygon, .node.kube > path {
    fill: #e2f2e9;
    stroke: #1f7a4d;
    stroke-width: 1.4;
  }
  .node.cli > polygon, .node.cli > path {
    fill: #eef0f1;
    stroke: #8a8f94;
    stroke-width: 1.2;
  }
  .node.cam > polygon, .node.cam > path {
    fill: #fbe3e3;
    stroke: #b3261e;
    stroke-width: 1.4;
  }
  .node.ap > polygon, .node.ap > path {
    fill: #f0e9e4;
    stroke: #7a5c48;
    stroke-width: 1.4;
  }
  .node.vip > polygon, .node.vip > path {
    fill: #faedda;
    stroke: #9a5800;
    stroke-width: 1.4;
  }
  @media (prefers-color-scheme: dark) {
    text {
      fill: #e6e6e3;
    }
    .cluster > polygon {
      stroke: #34363b;
    }
    .edge path, .edge polygon {
      stroke: #a3a3a0;
      fill: #a3a3a0;
    }
    .edge.wifi path {
      stroke: #7d8288;
    }
    .edge.vip path {
      stroke: #e0a34a;
    }
    .edge.vip polygon {
      stroke: #e0a34a;
      fill: #e0a34a;
    }
    .node.internet ellipse {
      fill: #23262b;
      stroke: #a3a3a0;
    }
    .node.net > polygon, .node.net > path {
      fill: #1b2540;
      stroke: #7aa2ff;
    }
    .node.srv > polygon, .node.srv > path {
      fill: #241d3a;
      stroke: #b49cff;
    }
    .node.kube > polygon, .node.kube > path {
      fill: #14291f;
      stroke: #5cc28e;
    }
    .node.cli > polygon, .node.cli > path {
      fill: #23262b;
      stroke: #8f9398;
    }
    .node.cam > polygon, .node.cam > path {
      fill: #33201f;
      stroke: #f2766d;
    }
    .node.ap > polygon, .node.ap > path {
      fill: #2b2320;
      stroke: #c9a58c;
    }
    .node.vip > polygon, .node.vip > path {
      fill: #2e2416;
      stroke: #e0a34a;
    }
  }
"""

def scope(css: str, root: str) -> str:
    """Prefix every selector with `root` so an inlined SVG cannot restyle the page."""
    out = []
    for line in css.splitlines():
        m = re.match(r"^(\s*)([^{}]+?)\s*\{\s*$", line)
        if m and not m.group(2).strip().startswith("@"):
            sels = [s.strip() for s in m.group(2).split(",") if s.strip()]
            line = m.group(1) + ", ".join(f"{root} {s}" for s in sels) + " {"
        out.append(line)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--inline", action="store_true", help="emit a scoped fragment")
    ap.add_argument("--embed", metavar="FILE", help="rewrite the marked block in FILE")
    args = ap.parse_args()

    svg = sys.stdin.read()
    if "<svg" not in svg:
        print("not an SVG on stdin", file=sys.stderr)
        return 1

    if args.inline or args.embed:
        style = f'<style type="text/css">{scope(CSS, "svg.diagram2")}</style>'
        svg = re.sub(r"(<svg[^>]*?)>", lambda m: m.group(1) + ' class="diagram2">' + style, svg, count=1)
    else:
        svg = re.sub(r"(<svg[^>]*>)", lambda m: m.group(1) + f'<style type="text/css">{CSS}</style>', svg, count=1)

    if args.embed:
        page = open(args.embed).read()
        pat = re.compile(r"(<!-- diagram:begin -->)(.*?)(<!-- diagram:end -->)", re.S)
        if not pat.search(page):
            print(f"no diagram:begin/end markers in {args.embed}", file=sys.stderr)
            return 1
        page = pat.sub(lambda m: m.group(1) + "\n" + svg + "\n" + m.group(3), page, count=1)
        open(args.embed, "w").write(page)
        print(f"embedded {len(svg)} bytes into {args.embed}", file=sys.stderr)
    else:
        sys.stdout.write(svg)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
