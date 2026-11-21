// Japanese is the official text; English is a courtesy translation.
(function(){
  var en = /^en\b/.test(new URLSearchParams(location.search).get('lang') || '') ||
           (!new URLSearchParams(location.search).get('lang') && !/^ja\b/.test(navigator.language || 'ja'));
  function set(isEn){
    document.body.classList.toggle('en', isEn);
    document.documentElement.lang = isEn ? 'en' : 'ja';
    document.querySelectorAll('.lang button').forEach(function(b){ b.classList.toggle('on', (b.dataset.l === 'en') === isEn); });
  }
  document.addEventListener('click', function(e){ var b = e.target.closest('.lang button'); if (b) set(b.dataset.l === 'en'); });
  set(en);
})();
