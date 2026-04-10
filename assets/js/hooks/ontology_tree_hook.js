// assets/js/hooks/ontology_tree_hook.js
//
// LiveView Hook that renders the organizational ontology as a visual tree
// with animated node cards, SVG connector lines, and hover tooltips.
//
// Usage in HEEx:
//   <div id="ontology-tree" phx-hook="OntologyTree" data-tree={Jason.encode!(@tree_data)}></div>

function cssVar(name, fallback) {
  const value = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return value || fallback;
}

function buildColorMap() {
  return {
    business: {
      stroke: cssVar("--zaq-ontology-business-stroke", "rgba(246,173,55,0.3)"),
      border: cssVar("--zaq-ontology-business-border", "rgba(246,173,55,0.25)"),
      bg: cssVar("--zaq-ontology-business-bg", "rgba(246,173,55,0.12)"),
      accent: cssVar("--zaq-ontology-business-accent", "#F6AD37"),
      glow: cssVar("--zaq-ontology-business-glow", "rgba(246,173,55,0.12)")
    },
    division: {
      stroke: cssVar("--zaq-ontology-division-stroke", "rgba(167,139,250,0.3)"),
      border: cssVar("--zaq-ontology-division-border", "rgba(167,139,250,0.18)"),
      bg: cssVar("--zaq-ontology-division-bg", "rgba(167,139,250,0.1)"),
      accent: cssVar("--zaq-ontology-division-accent", "#A78BFA"),
      glow: cssVar("--zaq-ontology-division-glow", "rgba(167,139,250,0.08)")
    },
    department: {
      stroke: cssVar("--zaq-ontology-department-stroke", "rgba(96,165,250,0.25)"),
      border: cssVar("--zaq-ontology-department-border", "rgba(96,165,250,0.18)"),
      bg: cssVar("--zaq-ontology-department-bg", "rgba(96,165,250,0.1)"),
      accent: cssVar("--zaq-ontology-department-accent", "#60A5FA"),
      glow: cssVar("--zaq-ontology-department-glow", "rgba(96,165,250,0.08)")
    },
    team: {
      stroke: cssVar("--zaq-ontology-team-stroke", "rgba(52,211,153,0.25)"),
      border: cssVar("--zaq-ontology-team-border", "rgba(52,211,153,0.18)"),
      bg: cssVar("--zaq-ontology-team-bg", "rgba(52,211,153,0.1)"),
      accent: cssVar("--zaq-ontology-team-accent", "#34D399"),
      glow: cssVar("--zaq-ontology-team-glow", "rgba(52,211,153,0.06)")
    },
    person: {
      stroke: cssVar("--zaq-ontology-person-stroke", "rgba(244,114,182,0.2)"),
      border: cssVar("--zaq-ontology-person-border", "rgba(244,114,182,0.14)"),
      bg: cssVar("--zaq-ontology-person-bg", "rgba(244,114,182,0.1)"),
      accent: cssVar("--zaq-ontology-person-accent", "#F472B6"),
      glow: cssVar("--zaq-ontology-person-glow", "rgba(244,114,182,0.06)")
    },
    domain: {
      stroke: cssVar("--zaq-ontology-domain-stroke", "rgba(251,146,60,0.2)"),
      border: cssVar("--zaq-ontology-domain-border", "rgba(251,146,60,0.16)"),
      bg: cssVar("--zaq-ontology-domain-bg", "rgba(251,146,60,0.1)"),
      accent: cssVar("--zaq-ontology-domain-accent", "#FB923C"),
      glow: cssVar("--zaq-ontology-domain-glow", "rgba(251,146,60,0.06)")
    }
  };
}

const OntologyTree = {
  mounted() {
    this.renderTree();
  },

  updated() {
    this.renderTree();
  },

  renderTree() {
    const raw = this.el.dataset.tree;
    if (!raw) return;

    let data;
    try {
      data = JSON.parse(raw);
    } catch (e) {
      console.error("[OntologyTree] Failed to parse tree data:", e);
      return;
    }

    const colorMap = buildColorMap();
    const uiFont = cssVar("--zaq-font-ui", "'Outfit',system-ui,sans-serif");
    const monoFont = cssVar("--zaq-font-mono", "'Space Mono',monospace");
    const emptyTextColor = cssVar("--zaq-ontology-empty-text", "#5A6A80");
    const emptyTitleColor = cssVar("--zaq-ontology-empty-title", "#A0AEC0");
    const tooltipBg = cssVar("--zaq-ontology-tooltip-bg", "rgba(14,20,35,0.92)");
    const tooltipBorder = cssVar("--zaq-ontology-tooltip-border", "rgba(255,255,255,0.08)");
    const tooltipShadow = cssVar("--zaq-ontology-tooltip-shadow", "0 12px 40px rgba(0,0,0,0.5)");
    const tooltipText = cssVar("--zaq-ontology-tooltip-text", "#A0AEC0");
    const nodeBg = cssVar("--zaq-ontology-node-bg", "linear-gradient(145deg, rgba(22,30,50,0.9), rgba(14,20,35,0.9))");
    const nodeTitleColor = cssVar("--zaq-ontology-node-title", "#EDF2F7");

    // If data is an array of businesses, wrap in a root node
    // If it's empty, show empty state
    if (Array.isArray(data) && data.length === 0) {
      this.el.innerHTML = `
        <div style="text-align:center; padding:4rem 2rem; color:${emptyTextColor}; font-family:${uiFont};">
          <p style="font-size:0.9rem; font-weight:600; color:${emptyTitleColor}; margin-bottom:0.5rem;">No ontology data yet</p>
          <p style="font-size:0.75rem;">Use the Org Structure tab to add businesses, divisions, departments and teams</p>
        </div>
      `;
      return;
    }

    // Clear previous render
    this.el.innerHTML = "";

    // Build container
    const wrapper = document.createElement("div");
    wrapper.style.cssText = "position:relative; overflow-x:auto; padding-bottom:2rem;";

    const svgEl = document.createElementNS("http://www.w3.org/2000/svg", "svg");
    svgEl.style.cssText = "position:absolute; top:0; left:0; width:100%; height:100%; pointer-events:none; z-index:0; overflow:visible;";

    const treeEl = document.createElement("div");
    treeEl.style.cssText = "display:flex; flex-direction:column; align-items:center; min-width:fit-content; position:relative; z-index:1;";

    // Legend
    const legend = document.createElement("div");
    legend.style.cssText = "display:flex; gap:0.875rem; flex-wrap:wrap; margin-bottom:1.5rem; justify-content:center;";
    const legendItems = [
      { label: "Business", color: colorMap.business.accent },
      { label: "Division", color: colorMap.division.accent },
      { label: "Department", color: colorMap.department.accent },
      { label: "Team", color: colorMap.team.accent },
      { label: "Person", color: colorMap.person.accent },
      { label: "Domain", color: colorMap.domain.accent }
    ];
    legendItems.forEach(({ label, color }) => {
      const item = document.createElement("span");
      item.style.cssText = `display:flex; align-items:center; gap:0.375rem; font-size:0.65rem; color:${tooltipText}; font-weight:500; text-transform:uppercase; letter-spacing:0.06em; font-family:${uiFont};`;
      const dot = document.createElement("span");
      dot.style.cssText = `width:7px; height:7px; border-radius:50%; background:${color}; box-shadow:0 0 6px ${color}40;`;
      item.appendChild(dot);
      item.appendChild(document.createTextNode(label));
      legend.appendChild(item);
    });

    // Tooltip
    const tooltip = document.createElement("div");
    tooltip.style.cssText = `position:fixed; z-index:1000; background:${tooltipBg}; backdrop-filter:blur(20px); -webkit-backdrop-filter:blur(20px); border:1px solid ${tooltipBorder}; border-radius:10px; padding:0.75rem 1rem; font-size:0.72rem; color:${tooltipText}; max-width:280px; pointer-events:none; opacity:0; transform:translateY(4px); transition:opacity 0.2s,transform 0.2s; box-shadow:${tooltipShadow}; line-height:1.55; font-family:${uiFont};`;

    let nodeIndex = 0;

    function buildNode(d) {
      const group = document.createElement("div");
      group.style.cssText = "display:flex; flex-direction:column; align-items:center; position:relative;";
      group.dataset.type = d.type;

      const colors = colorMap[d.type] || colorMap.business;
      const delay = nodeIndex * 0.04;
      nodeIndex++;

      const node = document.createElement("div");
      node.style.cssText = `
        background: ${nodeBg};
        border: 1px ${d.type === "domain" ? "dashed" : "solid"} ${colors.border};
        border-radius: 16px;
        padding: 0.875rem 1.25rem;
        min-width: ${d.type === "person" || d.type === "domain" ? "125px" : "145px"};
        max-width: ${d.type === "person" ? "170px" : d.type === "domain" ? "190px" : "220px"};
        text-align: center;
        cursor: default;
        transition: all 0.35s cubic-bezier(0.4,0,0.2,1);
        position: relative;
        opacity: 0;
        transform: translateY(16px) scale(0.95);
        animation: ontNodeReveal 0.6s cubic-bezier(0.16,1,0.3,1) forwards;
        animation-delay: ${delay}s;
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
        box-shadow: 0 4px 20px ${colors.glow};
      `.replace(/\n\s*/g, " ");

      node.addEventListener("mouseenter", () => {
        node.style.transform = "translateY(-3px) scale(1.02)";
        node.style.borderColor = colors.accent + "80";
        node.style.boxShadow = `0 8px 40px ${colors.glow}, 0 0 60px ${colors.glow}`;
      });
      node.addEventListener("mouseleave", () => {
        node.style.transform = "";
        node.style.borderColor = colors.border;
        node.style.boxShadow = `0 4px 20px ${colors.glow}`;
      });

      if (d.status === "inactive") {
        node.style.opacity = "0.4";
        node.style.filter = "grayscale(0.6)";
      }

      // Badge
      const badge = document.createElement("div");
      badge.style.cssText = `display:inline-block; font-size:0.52rem; font-weight:700; letter-spacing:0.1em; text-transform:uppercase; padding:0.2rem 0.6rem; border-radius:999px; margin-bottom:0.4rem; background:${colors.bg}; color:${colors.accent}; font-family:${uiFont};`;
      badge.textContent = d.type === "domain" ? "◇ domain" : d.type;
      node.appendChild(badge);

      // Name
      const name = document.createElement("div");
      const fontSize = d.type === "business" ? "1.05rem" : (d.type === "person" || d.type === "domain") ? "0.78rem" : "0.85rem";
      const fontWeight = d.type === "business" ? "700" : "600";
      const nameColor = d.type === "business" ? colors.accent : nodeTitleColor;
      name.style.cssText = `font-weight:${fontWeight}; font-size:${fontSize}; line-height:1.3; letter-spacing:-0.01em; color:${nameColor}; font-family:${uiFont};`;
      name.textContent = d.name;
      node.appendChild(name);

      // Detail
      if (d.type === "person" && d.role) {
        const detail = document.createElement("div");
        detail.style.cssText = `font-size:0.6rem; color:${emptyTextColor}; margin-top:0.3rem; font-family:${monoFont}; font-weight:400; letter-spacing:0.02em;`;
        detail.textContent = d.role;
        node.appendChild(detail);
      }
      if (d.type === "domain" && d.keywords && d.keywords.length > 0) {
        const detail = document.createElement("div");
        detail.style.cssText = `font-size:0.6rem; color:${emptyTextColor}; margin-top:0.3rem; font-family:${monoFont}; font-weight:400; letter-spacing:0.02em;`;
        detail.textContent = d.keywords.length + " keywords";
        node.appendChild(detail);
      }

      // Tooltip for domains
      if (d.type === "domain") {
        node.addEventListener("mouseenter", (e) => {
          let html = `<strong style="color:${nodeTitleColor}; font-weight:600;">${d.name}</strong>`;
          if (d.description) html += `<br>${d.description}`;
          if (d.keywords && d.keywords.length) {
            html += `<br><span style="display:inline-block; margin-top:0.35rem; font-family:${monoFont}; font-size:0.58rem; color:${colorMap.domain.accent}; opacity:0.85;">${d.keywords.join(" · ")}</span>`;
          }
          tooltip.innerHTML = html;
          tooltip.style.opacity = "1";
          tooltip.style.transform = "translateY(0)";
        });
        node.addEventListener("mousemove", (e) => {
          tooltip.style.left = e.clientX + 14 + "px";
          tooltip.style.top = e.clientY + 14 + "px";
        });
        node.addEventListener("mouseleave", () => {
          tooltip.style.opacity = "0";
          tooltip.style.transform = "translateY(4px)";
        });
      }

      group.appendChild(node);

      // Children
      if (d.children && d.children.length > 0) {
        const row = document.createElement("div");
        row.style.cssText = "display:flex; gap:1.5rem; position:relative; padding-top:2.5rem;";
        d.children.forEach((child) => {
          row.appendChild(buildNode(child));
        });
        group.appendChild(row);
      }

      return group;
    }

    // FIX 1: Handle array of businesses without duplicating a root node.
    // If it's a single business, render it directly as the root.
    // If multiple businesses, render each one side by side.
    if (Array.isArray(data)) {
      if (data.length === 1) {
        treeEl.appendChild(buildNode(data[0]));
      } else {
        const row = document.createElement("div");
        row.style.cssText = "display:flex; gap:2rem; position:relative;";
        data.forEach((biz) => {
          row.appendChild(buildNode(biz));
        });
        treeEl.appendChild(row);
      }
    } else {
      treeEl.appendChild(buildNode(data));
    }

    wrapper.appendChild(svgEl);
    wrapper.appendChild(treeEl);
    this.el.appendChild(legend);
    this.el.appendChild(wrapper);
    this.el.appendChild(tooltip);

    // Inject keyframe animation
    if (!document.getElementById("ont-tree-styles")) {
      const style = document.createElement("style");
      style.id = "ont-tree-styles";
      style.textContent = `
        @keyframes ontNodeReveal {
          from { opacity: 0; transform: translateY(16px) scale(0.95); }
          to { opacity: 1; transform: translateY(0) scale(1); }
        }
        @keyframes ontConnectorFadeIn {
          to { opacity: 1; }
        }
      `;
      document.head.appendChild(style);
    }

    // Draw SVG connectors after layout settles
    const drawConnectors = () => {
      while (svgEl.firstChild) svgEl.removeChild(svgEl.firstChild);

      const containerRect = wrapper.getBoundingClientRect();
      const scrollLeft = wrapper.scrollLeft;
      const scrollTop = wrapper.scrollTop;

      // SVG defs for gradients and glow filters
      const defs = document.createElementNS("http://www.w3.org/2000/svg", "defs");
      Object.keys(colorMap).forEach((type) => {
        const grad = document.createElementNS("http://www.w3.org/2000/svg", "linearGradient");
        grad.setAttribute("id", `ont-grad-${type}`);
        grad.setAttribute("x1", "0"); grad.setAttribute("y1", "0");
        grad.setAttribute("x2", "0"); grad.setAttribute("y2", "1");
        const s1 = document.createElementNS("http://www.w3.org/2000/svg", "stop");
        s1.setAttribute("offset", "0%"); s1.setAttribute("stop-color", colorMap[type].stroke);
        const s2 = document.createElementNS("http://www.w3.org/2000/svg", "stop");
        s2.setAttribute("offset", "100%"); s2.setAttribute("stop-color", colorMap[type].stroke.replace(/[\d.]+\)$/, "0.08)"));
        grad.appendChild(s1); grad.appendChild(s2);
        defs.appendChild(grad);

        const filter = document.createElementNS("http://www.w3.org/2000/svg", "filter");
        filter.setAttribute("id", `ont-glow-${type}`);
        filter.setAttribute("x", "-50%"); filter.setAttribute("y", "-50%");
        filter.setAttribute("width", "200%"); filter.setAttribute("height", "200%");
        const blur = document.createElementNS("http://www.w3.org/2000/svg", "feGaussianBlur");
        blur.setAttribute("stdDeviation", "3"); blur.setAttribute("result", "blur");
        filter.appendChild(blur);
        const merge = document.createElementNS("http://www.w3.org/2000/svg", "feMerge");
        const mn1 = document.createElementNS("http://www.w3.org/2000/svg", "feMergeNode");
        mn1.setAttribute("in", "blur");
        const mn2 = document.createElementNS("http://www.w3.org/2000/svg", "feMergeNode");
        mn2.setAttribute("in", "SourceGraphic");
        merge.appendChild(mn1); merge.appendChild(mn2);
        filter.appendChild(merge);
        defs.appendChild(filter);
      });
      svgEl.appendChild(defs);

      const connectorsFragment = document.createDocumentFragment();

      // Traverse node groups and draw curved paths
      wrapper.querySelectorAll("[data-type]").forEach((group) => {
        const parentNode = group.children[0]; // first child is the node card
        const childrenRow = group.children[1]; // second child is the children row

        // FIX 2: Proper check — ensure both elements exist and the children row
        // is a flex container with actual child groups inside it.
        if (!parentNode || !childrenRow) return;
        if (childrenRow.style.display !== "flex") return;

        const childGroups = childrenRow.children;
        if (!childGroups || childGroups.length === 0) return;

        const parentRect = parentNode.getBoundingClientRect();
        const px = parentRect.left + parentRect.width / 2 - containerRect.left + scrollLeft;
        const py = parentRect.bottom - containerRect.top + scrollTop;

        Array.from(childGroups).forEach((cg, i) => {
          const childNode = cg.children[0];
          if (!childNode) return;
          const childRect = childNode.getBoundingClientRect();
          const childType = cg.dataset.type || "department";

          const cx = childRect.left + childRect.width / 2 - containerRect.left + scrollLeft;
          const cy = childRect.top - containerRect.top + scrollTop;

          const midY = py + (cy - py) / 2;
          const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
          path.setAttribute("d", `M ${px} ${py} C ${px} ${midY}, ${cx} ${midY}, ${cx} ${cy}`);
          path.setAttribute("fill", "none");
          path.setAttribute("stroke", colorMap[childType]?.stroke || cssVar("--zaq-ontology-tooltip-border", "rgba(255,255,255,0.08)"));
          path.setAttribute("stroke-width", "1.5");
          path.setAttribute("filter", `url(#ont-glow-${childType})`);
          path.style.opacity = "0";
          path.style.animation = `ontConnectorFadeIn 0.8s ease forwards`;
          path.style.animationDelay = `${i * 0.05 + 0.3}s`;

          connectorsFragment.appendChild(path);
        });
      });

      svgEl.appendChild(connectorsFragment);

      const treeRect = treeEl.getBoundingClientRect();
      svgEl.style.width = Math.max(wrapper.scrollWidth, treeRect.width) + "px";
      svgEl.style.height = Math.max(wrapper.scrollHeight, treeRect.height + 100) + "px";
    };

    this._drawTimeouts = this._drawTimeouts || [];
    this._drawRaf = requestAnimationFrame(drawConnectors);

    const scheduleDraw = (delayMs) => {
      const timeoutId = setTimeout(() => {
        this._drawRaf = requestAnimationFrame(drawConnectors);
      }, delayMs);

      this._drawTimeouts.push(timeoutId);
    };

    scheduleDraw(150);
    scheduleDraw(800);
    scheduleDraw(1500);

    // Redraw on resize
    this._resizeHandler = () => {
      if (this._drawRaf) {
        cancelAnimationFrame(this._drawRaf);
      }

      this._drawRaf = requestAnimationFrame(drawConnectors);
    };
    window.addEventListener("resize", this._resizeHandler);
  },

  destroyed() {
    if (this._drawRaf) {
      cancelAnimationFrame(this._drawRaf);
      this._drawRaf = null;
    }

    if (Array.isArray(this._drawTimeouts)) {
      this._drawTimeouts.forEach((timeoutId) => clearTimeout(timeoutId));
      this._drawTimeouts = [];
    }

    if (this._resizeHandler) {
      window.removeEventListener("resize", this._resizeHandler);
      this._resizeHandler = null;
    }
  },
};

export default OntologyTree;
