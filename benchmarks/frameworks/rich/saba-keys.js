// Both measured Saba implementations own a keyed range. This fixture keeps keys
// stable across lanes and releases component owners when a filter removes them.
export function keyedBoard(lists, createCard) {
  let previous = new Map();
  return (lanes, selected) => {
    const retained = new Map();
    lanes.forEach((lane, i) => {
      const list = lists[i];
      let cursor = list.firstElementChild;
      for (const card of lane.cards) {
        let view = previous.get(card.id);
        if (view) view.update(card, card.id === selected);
        else view = createCard(list, card, card.id === selected);
        if (cursor !== view.node && !(cursor === null && list.lastElementChild === view.node)) {
          list.insertBefore(view.node, cursor);
        }
        cursor = view.node.nextElementSibling;
        retained.set(card.id, view);
      }
    });
    for (const [id, view] of previous) if (!retained.has(id)) view.dispose();
    previous = retained;
  };
}
