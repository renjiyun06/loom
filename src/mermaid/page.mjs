import mermaid from '/mermaid/mermaid.esm.min.mjs';
import zenuml from '/zenuml/mermaid-zenuml.esm.min.mjs';

await mermaid.registerExternalDiagrams([zenuml]);
mermaid.initialize({
  startOnLoad: false,
  securityLevel: 'strict',
  suppressErrorRendering: true,
  fontFamily: '"Microsoft YaHei UI", "Segoe UI", sans-serif',
});

// The published 12.3.0 renderer still recognizes the beta spelling.
const agentflowHeader = /^((?:\s*---[^\n]*\n[\s\S]*?\n---[^\n]*\n)?(?:\s*%%(?:\{[\s\S]*?\}%%|[^\n]*))*\s*)agentflow(?=\s|$)/;

window.renderDiagram = async (source) => {
  const target = document.querySelector('#diagram');
  const diagram = source.replace(agentflowHeader, '$1agentflow-beta');
  const { svg, diagramType } = await mermaid.render('loom-diagram', diagram);
  target.innerHTML = svg;
  const graphic = target.firstElementChild;
  if (!graphic) throw new Error('Mermaid did not return a diagram.');

  const box = graphic.viewBox?.baseVal;
  if (box?.width && box.height) {
    const scale = Math.min(1, 1280 / box.width, 8000 / box.height);
    graphic.style.width = Math.ceil(box.width * scale) + 'px';
    graphic.style.height = Math.ceil(box.height * scale) + 'px';
    graphic.style.maxWidth = 'none';
  }

  target.style.backgroundColor = mermaid.mermaidAPI.getConfig().theme === 'dark' ? '#25262a' : '';
  await document.fonts.ready;
  await Promise.allSettled(
    [...target.querySelectorAll('img')].map((image) => image.decode())
  );

  const bounds = target.getBoundingClientRect();
  return {
    diagramType,
    width: Math.ceil(bounds.width),
    height: Math.ceil(bounds.height),
  };
};
