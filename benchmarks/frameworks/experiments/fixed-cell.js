// A compiler specialization for one imperative input and one guaranteed text
// child. The ordinary reactive path owns bindings whose dependencies can vary.
class FixedTextCell {
  constructor(parent, record) {
    this.record = record;
    this.node = document.createElement('div');
    this.node.className = 'cell';
    this.node.dataset.id = String(record.id);
    this.label = document.createTextNode('');
    this.node.append(this.label);
    this.paint();
    parent.append(this.node);
  }

  paint() {
    const text = this.record.id + ' · ' + this.record.score;
    if (this.label.data !== text) this.label.data = text;
  }

  update(next) {
    if (this.record === null || Object.is(this.record, next)) return;
    this.record = next;
    this.paint();
  }

  dispose() {
    this.record = null;
    this.node.remove();
  }
}

export const mountCell = (parent, record) => new FixedTextCell(parent, record);
