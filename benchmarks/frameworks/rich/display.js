export const counters = [
  ['total', 'Tasks'],
  ['points', 'Points'],
  ['high', 'High priority'],
];

export function inspectorText(card) {
  return card.title + ' · ' + card.owner + ' · ' + card.priority + ' · ' + card.points + ' points';
}

export function barHeight(value, bins) {
  return 100 * value / Math.max(1, ...bins) + '%';
}
