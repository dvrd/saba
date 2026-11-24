const laneNames = ['Intake', 'Scheduled', 'In progress', 'Delivered'];
const owners = ['Ada', 'Bruno', 'Cleo', 'Dario', 'Emi', 'Farah', 'Gus', 'Hana'];
const subjects = ['Billing', 'Catalog', 'Search', 'Orders', 'Inventory', 'Shipping', 'Accounts', 'Returns'];
const tasks = ['audit', 'migration', 'rollout', 'review', 'integration', 'backfill'];

export function createBoard() {
  const cards = [];
  const order = laneNames.map(() => []);
  for (let i = 0; i < 240; i++) {
    const id = i + 1;
    const lane = i % laneNames.length;
    const ownerIndex = (i * 5 + Math.floor(i / 8)) % owners.length;
    const title = subjects[i % subjects.length] + ' ' + tasks[Math.floor(i / 8) % tasks.length] + ' ' + id;
    cards.push({
      id, title, lane, ownerIndex, owner: owners[ownerIndex],
      points: 1 + (i * 7) % 13, priority: i % 7 === 0 ? 'High' : 'Normal',
    });
    order[lane].push(id);
  }
  return {cards, order, revision: 0, selected: 1, filter: false, undo: null};
}

export function applyBoardAction(board, action) {
  const next = {...board, revision: board.revision + 1};
  switch (action.type) {
    case 'select':
      if (!Number.isInteger(action.id) || !board.cards[action.id - 1]) throw Error('Unknown card');
      return {...next, selected: action.id};
    case 'filter':
      return {...next, filter: !board.filter};
    case 'bulk':
      return {
        ...next, undo: {cards: board.cards, order: board.order},
        cards: board.cards.map(card => card.id % 5 === 0 ? {
          ...card, points: card.points + 3, priority: card.priority === 'High' ? 'Normal' : 'High',
        } : card),
      };
    case 'undo':
      if (!board.undo) throw Error('No board mutation to undo');
      return {...next, ...board.undo, undo: null};
    case 'drop': {
      const {id, lane, before} = action;
      const card = board.cards[id - 1];
      if (!Number.isInteger(id) || !card || !Number.isInteger(lane) || !board.order[lane]) {
        throw Error('Unknown drop origin or lane');
      }
      if (before === id || (before !== null && !board.order[lane].includes(before))) {
        throw Error('Drop anchor must be another card in the destination lane');
      }
      const order = board.order.map((ids, i) => i === lane || i === card.lane ? ids.filter(key => key !== id) : ids);
      const target = order[lane];
      target.splice(before === null ? target.length : target.indexOf(before), 0, id);
      const cards = board.cards.slice();
      cards[id - 1] = {...card, lane};
      return {...next, cards, order, undo: {cards: board.cards, order: board.order}};
    }
    default:
      throw Error('Unknown board action');
  }
}

export function boardSnapshot(board) {
  const bins = Array(owners.length).fill(0);
  let total = 0, points = 0, high = 0;
  const lanes = board.order.map((ids, lane) => {
    const cards = [];
    for (const id of ids) {
      const card = board.cards[id - 1];
      if (board.filter && card.priority !== 'High') continue;
      bins[card.ownerIndex] += card.points;
      total++;
      points += card.points;
      if (card.priority === 'High') high++;
      cards.push(card);
    }
    return {id: lane, name: laneNames[lane], cards};
  });
  return {
    revision: board.revision, selected: board.selected, filter: board.filter,
    total, points, high, bins, lanes, inspector: board.cards[board.selected - 1], canUndo: Boolean(board.undo),
  };
}
