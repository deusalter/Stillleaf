// These small choice sets expose the same value/change interface as a form
// control while keeping every option visible and keyboard reachable.
const groups = new Map();
const definitions = [
  ['font-weight', [['publisher', 'Original'], ['400', 'Regular'], ['700', 'Bold']]],
  ['text-align', [['publisher', 'Original'], ['start', 'Start'], ['justify', 'Justified']]],
  ['hyphens', [['publisher', 'Original'], ['true', 'On'], ['false', 'Off']]],
];

for (const [id, choices] of definitions) {
  const group = document.getElementById(id);
  let value = 'publisher';
  const sync = () => {
    for (const button of group.children) {
      const selected = button.dataset.value === value;
      button.setAttribute('aria-checked', String(selected));
      button.tabIndex = selected ? 0 : -1;
    }
  };
  const add = (key, label) => {
    const button = document.createElement('button');
    button.type = 'button';
    button.dataset.value = key;
    button.textContent = label;
    button.setAttribute('role', 'radio');
    if (key === 'publisher') button.title = 'Use the book’s original setting';
    button.onclick = () => {
      if (value === key) return;
      value = key;
      sync();
      group.dispatchEvent(new Event('change', {bubbles: true}));
    };
    group.append(button);
    return button;
  };
  for (const [key, label] of choices) add(key, label);
  Object.defineProperty(group, 'value', {
    get: () => value,
    set: next => {
      value = String(next);
      const custom = group.querySelector('[data-custom]');
      if (custom && custom.dataset.value !== value) custom.remove();
      if (![...group.children].some(button => button.dataset.value === value)) {
        const button = add(value, 'Custom');
        button.dataset.custom = 'true';
        button.title = `Saved text weight: ${value}`;
      }
      sync();
    },
  });
  group.addEventListener('keydown', event => {
    const step = {ArrowRight: 1, ArrowDown: 1, ArrowLeft: -1, ArrowUp: -1}[event.key];
    const items = [...group.children];
    const index = items.indexOf(document.activeElement);
    if (index < 0 || (!step && !['Home', 'End'].includes(event.key))) return;
    event.preventDefault();
    const next = event.key === 'Home' ? items[0] : event.key === 'End' ? items.at(-1)
      : items[(index + step + items.length) % items.length];
    next.focus();
    next.click();
  });
  sync();
  groups.set(id, group);
}

export function syncTypographyChoices(preferences) {
  groups.get('font-weight').value = preferences.fontWeight ?? 'publisher';
  groups.get('text-align').value = preferences.textAlign;
  groups.get('hyphens').value = preferences.hyphens ?? 'publisher';
}
