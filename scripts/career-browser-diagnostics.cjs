'use strict';
const fail = () => Object.assign(new Error('页面诊断格式无效'), { status: 400 });
function normalizeBrowserDiagnostic(raw) {
  if (!raw || raw.version !== 1 || raw.sourceID !== 'boss' || !['search', 'detail', 'other'].includes(raw.pageKind) ||
      !['loading', 'interactive', 'complete'].includes(raw.readyState) || !Array.isArray(raw.samples) || raw.samples.length > 2) throw fail();
  const count = value => {
    if (!Number.isSafeInteger(value) || value < 0 || value > 100000) throw fail();
    return value;
  };
  const nodes = (values, maximum) => {
    if (!Array.isArray(values) || values.length > maximum) throw fail();
    return values.map(node => {
      if (!/^[a-z][a-z0-9-]{0,30}$/.test(node?.tag) || !Array.isArray(node.classes) || node.classes.length > 8 ||
          node.classes.some(v => typeof v !== 'string' || !/^[a-z][a-z0-9_-]{0,79}$/i.test(v))) throw fail();
      return { tag: node.tag, classes: node.classes, textLength: count(node.textLength) };
    });
  };
  // Rebuild an allowlisted object. Never persist submitted page text, URL query
  // parameters, cookies, raw HTML, storage, or arbitrary extra request fields.
  return { version: 1, sourceID: 'boss', pageKind: raw.pageKind, readyState: raw.readyState,
    jobLinks: count(raw.jobLinks), cards: count(raw.cards), titleFields: count(raw.titleFields),
    companyFields: count(raw.companyFields), frames: count(raw.frames),
    samples: raw.samples.map(sample => ({ parents: nodes(sample.parents, 5), children: nodes(sample.children, 35) })) };
}
module.exports = { normalizeBrowserDiagnostic };
