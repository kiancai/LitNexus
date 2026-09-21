// 快速上手页：按浏览器平台自动切换 Mac / Windows 安装 tab。
// 仅在页面初始渲染、且当前仍是第一个（占位）tab 被选中时才切换，
// 因此不会覆盖用户在该页内的手动选择。
(function () {
  "use strict";

  function init() {
    var ua = navigator.userAgent || "";
    var platform = /Win/.test(ua)
      ? "windows"
      : /Mac|iPhone|iPad|iPod/.test(ua)
        ? "mac"
        : "";

    if (!platform) return;

    document.querySelectorAll(".tabbed-set").forEach(function (set) {
      var labels = Array.from(set.querySelectorAll("label"));
      var texts = labels.map(function (l) {
        return (l.textContent || "").toLowerCase();
      });
      // 只处理同时含 Mac 与 Windows 的安装 tab 组
      var hasMac = texts.some(function (t) { return t.indexOf("mac") > -1; });
      var hasWin = texts.some(function (t) { return t.indexOf("windows") > -1; });
      if (!hasMac || !hasWin) return;

      // 仅当占位（第一个）tab 仍处于选中时才切，避免覆盖用户选择
      var firstInput = set.querySelector("input[type=radio]");
      if (!firstInput || !firstInput.checked) return;

      var target = null;
      if (platform === "mac") {
        target = labels.find(function (l, i) {
          var t = texts[i];
          return t.indexOf("mac") > -1 && t.indexOf("windows") === -1;
        });
      } else {
        target = labels.find(function (l, i) {
          return texts[i].indexOf("windows") > -1;
        });
      }
      if (!target) return;

      var input = document.getElementById(target.getAttribute("for") || "");
      if (input && !input.checked) {
        input.checked = true;
        input.dispatchEvent(new Event("change", { bubbles: true }));
      }
    });
  }

  function run() {
    // Material instant navigation：每次切页都重新渲染 DOM
    if (typeof window.document$ !== "undefined") {
      window.document$.subscribe(init);
    }
    if (document.readyState === "loading") {
      document.addEventListener("DOMContentLoaded", init);
    } else {
      init();
    }
  }

  run();
})();