// The gallery's viewer. Every capture is a plain link to its image, so without this script (or in a browser with no
// <dialog>) a click still opens the picture. With it, a click opens the picture large over the page: Left and Right go
// through the captures, Home and End to the first and the last, Esc or a click on the picture closes, and the keyboard
// comes back to the link of the capture last shown. No dependency.
(function () {
  'use strict';

  var links = Array.prototype.slice.call(document.querySelectorAll('.gallery a.frame'));
  var box = document.createElement('dialog');
  if (!links.length || typeof box.showModal !== 'function') return;

  function make(tag, cls, text) {
    var el = document.createElement(tag);
    el.className = cls;
    if (text) el.textContent = text;
    return el;
  }
  function button(cls, text, action) {
    var b = make('button', cls, text);
    b.type = 'button';
    b.addEventListener('click', action);
    return b;
  }

  var current = 0;
  var stage = make('div', 'lightbox-stage');
  var picture = document.createElement('img');
  var caption = make('p', 'lightbox-caption');
  var count = make('span', 'lightbox-count');
  var full = make('a', 'btn', 'Full size');
  var closer = button('btn primary', 'Close', close);

  count.setAttribute('aria-live', 'polite');
  full.title = 'The image alone, at its own size';
  stage.appendChild(picture);
  stage.addEventListener('click', close);

  var actions = make('div', 'lightbox-actions');
  actions.appendChild(count);
  actions.appendChild(button('btn', 'Previous', function () { show(current - 1); }));
  actions.appendChild(button('btn', 'Next', function () { show(current + 1); }));
  actions.appendChild(full);
  actions.appendChild(closer);

  var bar = make('div', 'lightbox-bar');
  bar.appendChild(caption);
  bar.appendChild(actions);

  box.className = 'lightbox';
  box.setAttribute('aria-label', 'Screenshot');
  box.appendChild(stage);
  box.appendChild(bar);
  document.body.appendChild(box);

  function show(i) {
    current = (i + links.length) % links.length;
    var link = links[current];
    var thumb = link.querySelector('img');
    var text = link.parentNode.querySelector('figcaption');
    picture.removeAttribute('src');   // never the last picture under this caption while the next one loads
    picture.alt = thumb ? thumb.alt : '';
    picture.src = link.getAttribute('href');
    full.href = link.getAttribute('href');
    count.textContent = (current + 1) + ' / ' + links.length;
    while (caption.firstChild) caption.removeChild(caption.firstChild);
    if (text) {
      for (var n = text.firstChild; n; n = n.nextSibling) caption.appendChild(n.cloneNode(true));
    }
  }

  function open(i) {
    show(i);
    document.documentElement.classList.add('lightbox-open');
    box.showModal();
    closer.focus();
  }

  function close() {
    if (box.open) box.close();
    done();
  }

  // once, whichever way the viewer closed (the close button, the picture, or the browser's own Esc)
  function done() {
    if (!document.documentElement.classList.contains('lightbox-open')) return;
    document.documentElement.classList.remove('lightbox-open');
    picture.removeAttribute('src');
    links[current].focus();
  }
  box.addEventListener('close', done);

  box.addEventListener('keydown', function (e) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    switch (e.key) {
      case 'Escape': close(); break;
      case 'ArrowLeft': show(current - 1); break;
      case 'ArrowRight': show(current + 1); break;
      case 'Home': show(0); break;
      case 'End': show(links.length - 1); break;
      default: return;
    }
    e.preventDefault();
  });

  links.forEach(function (link, i) {
    link.addEventListener('click', function (e) {
      if (e.button !== 0 || e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;   // a new tab, as asked
      e.preventDefault();
      open(i);
    });
  });
})();
