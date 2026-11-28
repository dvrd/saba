import {applyBoardAction, boardSnapshot, createBoard} from './board-model.js';

const transitionMs = 300;
const cardSelector = '.rich-card[data-id]';
const laneSelector = '.rich-lane[data-lane]';

function statusPaint(id, message) {
  const indicator = document.createElement('span');
  indicator.setAttribute('elementtiming', id);
  indicator.textContent = message;
  document.getElementById('bench-status').replaceChildren(indicator);
}

function visiblePositions(host) {
  const positions = new Map();
  for (const lane of host.querySelectorAll(laneSelector)) {
    const list = lane.querySelector('[id^="lane-items-"]');
    const bounds = list.getBoundingClientRect();
    const top = Math.max(0, bounds.top);
    const bottom = Math.min(innerHeight, bounds.bottom);
    for (const node of list.children) {
      const rect = node.getBoundingClientRect();
      if (rect.bottom > top && rect.top < bottom && rect.right > 0 && rect.left < innerWidth) {
        positions.set(Number(node.dataset.id), {node, x: rect.x, y: rect.y, width:rect.width, lane:lane.dataset.lane});
      }
    }
  }
  return positions;
}

function animateReorder(before, after, targetId, pointerMoves) {
  const animations = [];
  const flights = [];
  const moved = [];
  for (const [id, next] of after) {
    if (!before.has(id)) continue;
    const previous = before.get(id);
    const dx = previous.x - next.x, dy = previous.y - next.y;
    if (Math.abs(dx) + Math.abs(dy) < 1) continue;
    moved.push({id, dx, dy, fromLane:Number(previous.lane), toLane:Number(next.lane)});
    let animated = next.node;
    if (previous.lane !== next.lane) {
      // A card animating inside its new scroll container would be clipped while
      // crossing the gutter. Paint its flight in viewport coordinates.
      animated = next.node.cloneNode(true);
      animated.removeAttribute('id');
      animated.removeAttribute('data-id');
      animated.setAttribute('aria-hidden', 'true');
      animated.classList.add('rich-flight');
      Object.assign(animated.style, {left:next.x+'px', top:next.y+'px', width:next.width+'px'});
      document.body.appendChild(animated);
      next.node.classList.add('rich-in-flight');
      flights.push([animated, next.node]);
    }
    animations.push(animated.animate([
      {transform: 'translate(' + dx + 'px,' + dy + 'px)'},
      {transform: 'translate(0,0)'},
    ], {duration: transitionMs, easing: 'cubic-bezier(.2,.7,.2,1)'}));
  }
  const frames = [];
  const started = performance.now();
  let raf;
  function sample(time) {
    frames.push(time);
    raf = requestAnimationFrame(sample);
  }
  raf = requestAnimationFrame(sample);
  const result = {targetId, pointerMoves, configuredMs: transitionMs, durationMs: 0, moved, frames};
  const finished = Promise.all(animations.map(animation => animation.finished)).then(() => {
    cancelAnimationFrame(raf);
    for (const [overlay, card] of flights) {
      overlay.remove();
      card.classList.remove('rich-in-flight');
    }
    result.durationMs = performance.now() - started;
  });
  return {result, finished};
}

// All renderers commit the same view model. The htmx adapter additionally sends
// the action to its server, which applies it to an independent board.
export async function startDashboard(mount) {
  const host = document.getElementById('app');
  const lifecycle = window.richDashboard = {phase: 'loading', revision: -1, lastAnimation: null};
  const failure = error => {
    lifecycle.phase = 'failed';
    lifecycle.error = String(error?.stack || error);
    document.documentElement.dataset.failure = lifecycle.error;
    console.error(error);
  };
  try {
    let board = createBoard();
    const update = await mount(host, boardSnapshot(board));
    let drag = null;
    let suppressClick = false;

    async function dispatch(action, eventTime, pointerMoves = 0) {
      if (lifecycle.phase !== 'idle') return;
      lifecycle.phase = 'updating';
      performance.mark('rich-' + action.type + '-start', {startTime: eventTime});
      try {
        const before = action.type === 'drop' ? visiblePositions(host) : null;
        const next = applyBoardAction(board, action);
        await update(boardSnapshot(next), action);
        board = next;
        lifecycle.revision = board.revision;
        const animation = before && animateReorder(before, visiblePositions(host), action.id, pointerMoves);
        performance.mark('rich-' + action.type + '-commit');
        statusPaint('rich-view-' + board.revision, 'Board updated · ' + board.revision);
        if (animation) {
          lifecycle.phase = 'animating';
          lifecycle.lastAnimation = animation.result;
          await animation.finished;
          performance.mark('rich-drop-finish');
          statusPaint('rich-drop-painted-' + board.revision, 'Move complete · ' + board.revision);
        }
        lifecycle.phase = 'idle';
      } catch (error) { failure(error); }
    }

    host.addEventListener('click', event => {
      if (suppressClick) return;
      const button = event.target.closest('#bulk, #undo, #filter');
      if (button && !button.disabled) {
        void dispatch({type: button.id}, event.timeStamp);
        return;
      }
      const card = event.target.closest(cardSelector);
      if (card) void dispatch({type:'select', id:Number(card.dataset.id)}, event.timeStamp);
    });
    host.addEventListener('keydown', event => {
      if (event.key !== 'Enter' && event.key !== ' ') return;
      const card = event.target.closest(cardSelector);
      if (card) {
        event.preventDefault();
        void dispatch({type:'select', id:Number(card.dataset.id)}, event.timeStamp);
      }
    });

    host.addEventListener('pointerdown', event => {
      if (event.button !== 0 || !event.isPrimary || lifecycle.phase !== 'idle') return;
      const origin = event.target.closest(cardSelector);
      if (!origin) return;
      drag = {origin, pointer:event.pointerId, x:event.clientX, y:event.clientY, moves:0, ghost:null};
    });
    host.addEventListener('pointermove', event => {
      if (!drag || drag.pointer !== event.pointerId) return;
      const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
      if (!drag.ghost) {
        if (Math.hypot(dx, dy) < 5) return;
        host.setPointerCapture(event.pointerId);
        const rect = drag.origin.getBoundingClientRect();
        const ghost = drag.origin.cloneNode(true);
        ghost.removeAttribute('id');
        ghost.removeAttribute('data-id');
        ghost.setAttribute('aria-hidden', 'true');
        ghost.classList.add('rich-ghost');
        Object.assign(ghost.style, {left:rect.left+'px', top:rect.top+'px', width:rect.width+'px'});
        document.body.appendChild(ghost);
        drag.origin.classList.add('rich-drag-origin');
        drag.ghost = ghost;
      }
      drag.moves++;
      drag.ghost.style.transform = 'translate3d(' + dx + 'px,' + dy + 'px,0)';
    });

    function release() {
      if (drag?.ghost) {
        drag.ghost.remove();
        drag.origin.classList.remove('rich-drag-origin');
        if (host.hasPointerCapture(drag.pointer)) host.releasePointerCapture(drag.pointer);
      }
      drag = null;
    }
    host.addEventListener('pointercancel', release);
    window.addEventListener('blur', release);
    host.addEventListener('pointerup', event => {
      if (!drag || event.pointerId !== drag.pointer) return;
      if (!drag.ghost) { release(); return; }
      const id = Number(drag.origin.dataset.id);
      const moves = drag.moves;
      release();
      suppressClick = true;
      setTimeout(() => { suppressClick = false; }, 0);
      const hit = document.elementFromPoint(event.clientX, event.clientY);
      const lane = hit?.closest(laneSelector);
      if (!lane) return;
      const anchor = hit.closest(cardSelector);
      let next = anchor;
      if (anchor) {
        const rect = anchor.getBoundingClientRect();
        if (event.clientY > rect.top + rect.height / 2) next = anchor.nextElementSibling;
      } else if (!hit.closest('[id^="lane-items-"]')) {
        next = lane.querySelector(cardSelector);
      }
      const before = next ? Number(next.dataset.id) : null;
      if (before === id) return;
      void dispatch({type:'drop', id, lane:Number(lane.dataset.lane), before}, event.timeStamp, moves);
    });
    performance.mark('rich-ready');
    statusPaint('rich-view-0', 'Board ready');
    lifecycle.revision = board.revision;
    lifecycle.phase = 'idle';
  } catch (error) { failure(error); }
}
