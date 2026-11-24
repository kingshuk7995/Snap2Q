(() => {
  const STORAGE_KEY = "pharma_qbank_progress_v1";
  const NAV_PAGE_SIZE = 100;

  const state = {
    allQuestions: [],
    filtered: [],
    currentIndex: 0,
    filter: "all",
    shuffled: false,
    mode: "practice", // 'practice' | 'exam'
    examSubmitted: false,
    examPicks: {}, // qid -> 'A'|'B'|'C'|'D'
    examStartMs: null,
    examTimerId: null,
    navPage: 0,
    progress: {
      answers: {},    // qid -> { pick, correct, ts }
      bookmarks: {},  // qid -> true
      notes: {},      // qid -> string
      lastId: 1,
    },
  };

  const $ = (id) => document.getElementById(id);

  // DOM refs
  const els = {
    sidebar: $("sidebar"),
    navGrid: $("nav-grid"),
    navCount: $("nav-count"),
    navPageLabel: $("nav-page-label"),
    navPrevPage: $("nav-prev-page"),
    navNextPage: $("nav-next-page"),
    jumpInput: $("jump-input"),
    jumpQBtn: $("jump-q-btn"),
    jumpPBtn: $("jump-p-btn"),
    loading: $("loading-state"),
    empty: $("empty-state"),
    quiz: $("quiz-container"),
    qBadge: $("q-badge"),
    qPageBadge: $("q-page-badge"),
    qDiagramBadge: $("q-diagram-badge"),
    qPosition: $("q-position"),
    qImage: $("q-image"),
    eImage: $("e-image"),
    expSection: $("explanation-section"),
    feedback: $("feedback-banner"),
    optionsRow: $("options-row"),
    btnPrev: $("btn-prev"),
    btnNext: $("btn-next"),
    btnToggleExp: $("btn-toggle-exp"),
    btnSubmitExam: $("btn-submit-exam"),
    btnBookmark: $("btn-bookmark"),
    btnZoomQ: $("btn-zoom-q"),
    btnZoomE: $("btn-zoom-e"),
    btnShuffle: $("btn-shuffle"),
    btnTheme: $("btn-theme"),
    btnSidebar: $("btn-sidebar"),
    btnReset: $("btn-reset"),
    btnClearFilter: $("btn-clear-filter"),
    filterSelect: $("filter-select"),
    statDone: $("stat-done"),
    statAcc: $("stat-acc"),
    examTimerPill: $("exam-timer-pill"),
    examTimer: $("exam-timer"),
    notes: $("q-notes"),
    lightbox: $("lightbox"),
    lightboxImg: $("lightbox-img"),
    lightboxClose: $("lightbox-close"),
    modal: $("settings-modal"),
    modalClose: $("modal-close"),
    mTotal: $("m-total"),
    mCorrect: $("m-correct"),
    mWrong: $("m-wrong"),
    mBookmarked: $("m-bookmarked"),
    btnExport: $("btn-export-progress"),
    btnImport: $("btn-import-progress"),
    importFile: $("import-file-input"),
    btnResetResponses: $("btn-reset-responses"),
    btnClearProgress: $("btn-clear-progress"),
    modePractice: $("mode-practice"),
    modeExam: $("mode-exam"),
  };

  const IS_STANDALONE = typeof window.QBANK_DATA !== "undefined";

  function resolveImageSrc(relPath) {
    if (window.QBANK_IMAGES && window.QBANK_IMAGES[relPath]) {
      return "data:image/webp;base64," + window.QBANK_IMAGES[relPath];
    }
    return IS_STANDALONE ? `./${relPath}` : `/data/${relPath}`;
  }

  // --- Persistence ---
  let saveTimer = null;
  function saveProgress() {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(state.progress));
    } catch (_) {}
    if (IS_STANDALONE) return;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(() => {
      fetch("/api/progress", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(state.progress),
      }).catch(() => {});
    }, 300);
  }

  async function loadProgress() {
    let local = null;
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (raw) local = JSON.parse(raw);
    } catch (_) {}

    let remote = null;
    if (!IS_STANDALONE) {
      try {
        const res = await fetch("/api/progress");
        if (res.ok) remote = await res.json();
      } catch (_) {}
    }

    const pickSource = (a, b) => {
      const countA = Object.keys(a?.answers || {}).length + Object.keys(a?.bookmarks || {}).length;
      const countB = Object.keys(b?.answers || {}).length + Object.keys(b?.bookmarks || {}).length;
      return countB > countA ? b : a;
    };

    const best = pickSource(local, remote);
    if (best && typeof best === "object") {
      state.progress = {
        answers: best.answers || {},
        bookmarks: best.bookmarks || {},
        notes: best.notes || {},
        lastId: best.lastId || 1,
      };
    }
  }

  // --- Filtering & Ordering ---
  function applyFilter(preserveId = null) {
    const f = state.filter;
    let list = state.allQuestions.filter((q) => {
      const rec = state.progress.answers[q.id];
      if (f === "unattempted") return !rec;
      if (f === "incorrect") return rec && !rec.correct;
      if (f === "correct") return rec && rec.correct;
      if (f === "bookmarked") return !!state.progress.bookmarks[q.id];
      if (f === "diagram") return !!q.has_diagram;
      return true;
    });

    if (state.shuffled) {
      list = [...list];
      for (let i = list.length - 1; i > 0; i--) {
        const j = Math.floor(Math.random() * (i + 1));
        [list[i], list[j]] = [list[j], list[i]];
      }
    }

    state.filtered = list;
    if (preserveId != null) {
      const idx = list.findIndex((q) => q.id === preserveId);
      state.currentIndex = idx >= 0 ? idx : 0;
    } else {
      state.currentIndex = Math.min(state.currentIndex, Math.max(0, list.length - 1));
    }
    state.navPage = Math.floor(state.currentIndex / NAV_PAGE_SIZE);
    render();
  }

  function currentQuestion() {
    return state.filtered[state.currentIndex] || null;
  }

  // --- Rendering ---
  function updateStats() {
    const total = state.allQuestions.length;
    const answers = Object.values(state.progress.answers);
    const done = answers.length;
    const correct = answers.filter((a) => a.correct).length;
    const wrong = done - correct;
    const bookmarked = Object.keys(state.progress.bookmarks).filter((k) => state.progress.bookmarks[k]).length;

    els.statDone.textContent = `${done}/${total}`;
    els.statAcc.textContent = done ? `${Math.round((correct / done) * 100)}%` : "—";
    els.mTotal.textContent = total;
    els.mCorrect.textContent = correct;
    els.mWrong.textContent = wrong;
    els.mBookmarked.textContent = bookmarked;
  }

  function renderNav() {
    const total = state.filtered.length;
    els.navCount.textContent = `${total} items`;
    const maxPage = Math.max(0, Math.ceil(total / NAV_PAGE_SIZE) - 1);
    state.navPage = Math.min(state.navPage, maxPage);

    const start = state.navPage * NAV_PAGE_SIZE;
    const end = Math.min(total, start + NAV_PAGE_SIZE);
    els.navPageLabel.textContent = total ? `${start + 1}–${end}` : "0";
    els.navPrevPage.disabled = state.navPage <= 0;
    els.navNextPage.disabled = state.navPage >= maxPage;

    const frag = document.createDocumentFragment();
    for (let i = start; i < end; i++) {
      const q = state.filtered[i];
      const btn = document.createElement("button");
      btn.className = "nav-cell";
      btn.textContent = q.id;
      if (i === state.currentIndex) btn.classList.add("current");
      if (state.progress.bookmarks[q.id]) btn.classList.add("bookmarked");

      if (state.mode === "exam" && !state.examSubmitted) {
        if (state.examPicks[q.id]) btn.classList.add("exam-picked");
      } else {
        const rec = state.progress.answers[q.id];
        if (rec) btn.classList.add(rec.correct ? "correct" : "wrong");
      }

      btn.addEventListener("click", () => {
        state.currentIndex = i;
        render();
        if (window.innerWidth <= 820) els.sidebar.classList.add("collapsed");
      });
      frag.appendChild(btn);
    }
    els.navGrid.innerHTML = "";
    els.navGrid.appendChild(frag);
  }

  function render() {
    updateStats();
    renderNav();

    const q = currentQuestion();
    if (!q) {
      els.quiz.classList.add("hidden");
      els.empty.classList.remove("hidden");
      return;
    }

    els.empty.classList.add("hidden");
    els.quiz.classList.remove("hidden");

    state.progress.lastId = q.id;
    els.qBadge.textContent = `Q #${q.id}`;
    els.qPageBadge.textContent = `PDF Page ${q.page}`;
    els.qDiagramBadge.classList.toggle("hidden", !q.has_diagram);
    els.qPosition.textContent = `${state.currentIndex + 1} of ${state.filtered.length}`;

    const isBookmarked = !!state.progress.bookmarks[q.id];
    els.btnBookmark.classList.toggle("active", isBookmarked);
    els.btnBookmark.textContent = isBookmarked ? "★ Bookmarked" : "☆ Bookmark";

    els.qImage.src = resolveImageSrc(q.q_img);
    els.eImage.src = resolveImageSrc(q.e_img);

    // Preload next question image for instant navigation
    const nextQ = state.filtered[state.currentIndex + 1];
    if (nextQ) {
      const pre = new Image();
      pre.src = resolveImageSrc(nextQ.q_img);
    }

    // Notes
    els.notes.value = state.progress.notes[q.id] || "";

    // Option buttons & feedback
    const buttons = els.optionsRow.querySelectorAll(".opt-btn");
    const rec = state.progress.answers[q.id];
    const inActiveExam = state.mode === "exam" && !state.examSubmitted;

    els.btnSubmitExam.classList.toggle("hidden", !inActiveExam);

    buttons.forEach((btn) => {
      const opt = btn.dataset.opt;
      btn.className = "opt-btn";
      btn.disabled = false;

      if (inActiveExam) {
        if (state.examPicks[q.id] === opt) btn.classList.add("selected");
      } else if (rec) {
        btn.disabled = true;
        if (opt === q.answer) btn.classList.add("correct");
        if (opt === rec.pick && !rec.correct) btn.classList.add("wrong");
      }
    });

    if (inActiveExam) {
      els.feedback.classList.add("hidden");
      els.expSection.classList.add("hidden");
      els.btnToggleExp.classList.add("hidden");
    } else if (rec) {
      els.feedback.classList.remove("hidden", "good", "bad");
      if (rec.correct) {
        els.feedback.classList.add("good");
        els.feedback.textContent = `✓ Correct! Option ${q.answer} is right.`;
      } else {
        els.feedback.classList.add("bad");
        els.feedback.textContent = `✕ Incorrect — You picked ${rec.pick}. Correct answer: Option ${q.answer}.`;
      }
      els.expSection.classList.remove("hidden");
      els.btnToggleExp.classList.remove("hidden");
      els.btnToggleExp.textContent = "Hide Explanation (E)";
    } else {
      els.feedback.classList.add("hidden");
      els.expSection.classList.add("hidden");
      els.btnToggleExp.classList.remove("hidden");
      els.btnToggleExp.textContent = "Reveal Explanation (E)";
    }

    els.btnPrev.disabled = state.currentIndex <= 0;
    els.btnNext.disabled = state.currentIndex >= state.filtered.length - 1;
  }

  // --- Interactions ---
  function pickOption(opt) {
    const q = currentQuestion();
    if (!q) return;

    if (state.mode === "exam" && !state.examSubmitted) {
      state.examPicks[q.id] = opt;
      render();
      return;
    }

    if (state.progress.answers[q.id]) return;
    const isCorrect = q.answer === opt;
    state.progress.answers[q.id] = { pick: opt, correct: isCorrect, ts: Date.now() };
    saveProgress();
    render();
  }

  function submitExam() {
    const entries = Object.entries(state.examPicks);
    if (!entries.length) {
      alert("Pick at least one answer before submitting the exam.");
      return;
    }
    let right = 0;
    for (const [qidStr, pick] of entries) {
      const qid = Number(qidStr);
      const q = state.allQuestions.find((x) => x.id === qid);
      if (!q) continue;
      const correct = q.answer === pick;
      if (correct) right++;
      state.progress.answers[qid] = { pick, correct, ts: Date.now() };
    }
    state.examSubmitted = true;
    stopExamTimer();
    saveProgress();
    render();
    alert(`Exam submitted!\nScore: ${right} / ${entries.length} (${Math.round((right / entries.length) * 100)}%)`);
  }

  function startExamTimer() {
    stopExamTimer();
    state.examStartMs = Date.now();
    els.examTimerPill.classList.remove("hidden");
    const tick = () => {
      const secs = Math.floor((Date.now() - state.examStartMs) / 1000);
      const mm = String(Math.floor(secs / 60)).padStart(2, "0");
      const ss = String(secs % 60).padStart(2, "0");
      els.examTimer.textContent = `${mm}:${ss}`;
    };
    tick();
    state.examTimerId = setInterval(tick, 1000);
  }

  function stopExamTimer() {
    if (state.examTimerId) {
      clearInterval(state.examTimerId);
      state.examTimerId = null;
    }
  }

  function setMode(mode) {
    state.mode = mode;
    els.modePractice.classList.toggle("active", mode === "practice");
    els.modeExam.classList.toggle("active", mode === "exam");
    if (mode === "exam") {
      state.examSubmitted = false;
      state.examPicks = {};
      startExamTimer();
    } else {
      stopExamTimer();
      els.examTimerPill.classList.add("hidden");
    }
    render();
  }

  function toggleExplanation() {
    if (state.mode === "exam" && !state.examSubmitted) return;
    const hidden = els.expSection.classList.toggle("hidden");
    els.btnToggleExp.textContent = hidden ? "Show Explanation (E)" : "Hide Explanation (E)";
  }

  function openLightbox(src) {
    els.lightboxImg.src = src;
    els.lightbox.classList.remove("hidden");
  }

  function closeLightbox() {
    els.lightbox.classList.add("hidden");
  }

  function bindEvents() {
    els.optionsRow.addEventListener("click", (e) => {
      const btn = e.target.closest(".opt-btn");
      if (btn && !btn.disabled) pickOption(btn.dataset.opt);
    });

    els.btnPrev.addEventListener("click", () => {
      if (state.currentIndex > 0) {
        state.currentIndex--;
        state.navPage = Math.floor(state.currentIndex / NAV_PAGE_SIZE);
        render();
        window.scrollTo({ top: 0, behavior: "smooth" });
      }
    });

    els.btnNext.addEventListener("click", () => {
      if (state.currentIndex < state.filtered.length - 1) {
        state.currentIndex++;
        state.navPage = Math.floor(state.currentIndex / NAV_PAGE_SIZE);
        render();
        window.scrollTo({ top: 0, behavior: "smooth" });
      }
    });

    els.btnToggleExp.addEventListener("click", toggleExplanation);
    els.btnSubmitExam.addEventListener("click", submitExam);

    els.btnBookmark.addEventListener("click", () => {
      const q = currentQuestion();
      if (!q) return;
      if (state.progress.bookmarks[q.id]) delete state.progress.bookmarks[q.id];
      else state.progress.bookmarks[q.id] = true;
      saveProgress();
      render();
    });

    els.filterSelect.addEventListener("change", () => {
      state.filter = els.filterSelect.value;
      applyFilter();
    });

    els.btnClearFilter.addEventListener("click", () => {
      state.filter = "all";
      els.filterSelect.value = "all";
      applyFilter();
    });

    els.btnShuffle.addEventListener("click", () => {
      state.shuffled = !state.shuffled;
      els.btnShuffle.classList.toggle("active", state.shuffled);
      const q = currentQuestion();
      applyFilter(q?.id);
    });

    els.modePractice.addEventListener("click", () => setMode("practice"));
    els.modeExam.addEventListener("click", () => setMode("exam"));

    els.btnSidebar.addEventListener("click", () => {
      els.sidebar.classList.toggle("collapsed");
    });

    els.navPrevPage.addEventListener("click", () => {
      if (state.navPage > 0) {
        state.navPage--;
        renderNav();
      }
    });

    els.navNextPage.addEventListener("click", () => {
      state.navPage++;
      renderNav();
    });

    els.jumpQBtn.addEventListener("click", () => {
      const val = Number(els.jumpInput.value);
      if (!val) return;
      let idx = state.filtered.findIndex((q) => q.id === val);
      if (idx < 0) {
        state.filter = "all";
        els.filterSelect.value = "all";
        applyFilter(val);
        return;
      }
      state.currentIndex = idx;
      state.navPage = Math.floor(idx / NAV_PAGE_SIZE);
      render();
    });

    els.jumpPBtn.addEventListener("click", () => {
      const page = Number(els.jumpInput.value);
      if (!page) return;
      let idx = state.filtered.findIndex((q) => q.page === page);
      if (idx < 0) {
        state.filter = "all";
        els.filterSelect.value = "all";
        applyFilter();
        idx = state.filtered.findIndex((q) => q.page === page);
      }
      if (idx >= 0) {
        state.currentIndex = idx;
        state.navPage = Math.floor(idx / NAV_PAGE_SIZE);
        render();
      }
    });

    els.notes.addEventListener("input", () => {
      const q = currentQuestion();
      if (!q) return;
      const val = els.notes.value;
      if (val.trim()) state.progress.notes[q.id] = val;
      else delete state.progress.notes[q.id];
      saveProgress();
    });

    // Zoom
    els.qImage.addEventListener("click", () => openLightbox(els.qImage.src));
    els.eImage.addEventListener("click", () => openLightbox(els.eImage.src));
    els.btnZoomQ.addEventListener("click", () => openLightbox(els.qImage.src));
    els.btnZoomE.addEventListener("click", () => openLightbox(els.eImage.src));
    els.lightboxClose.addEventListener("click", closeLightbox);
    els.lightbox.addEventListener("click", (e) => {
      if (e.target === els.lightbox) closeLightbox();
    });

    // Theme
    const savedTheme = localStorage.getItem("pharma_qbank_theme") || "light";
    document.documentElement.setAttribute("data-theme", savedTheme);
    els.btnTheme.textContent = savedTheme === "dark" ? "☀" : "☾";
    els.btnTheme.addEventListener("click", () => {
      const next = document.documentElement.getAttribute("data-theme") === "dark" ? "light" : "dark";
      document.documentElement.setAttribute("data-theme", next);
      localStorage.setItem("pharma_qbank_theme", next);
      els.btnTheme.textContent = next === "dark" ? "☀" : "☾";
    });

    // Settings Modal
    els.btnReset.addEventListener("click", () => els.modal.classList.remove("hidden"));
    els.modalClose.addEventListener("click", () => els.modal.classList.add("hidden"));
    els.modal.addEventListener("click", (e) => {
      if (e.target === els.modal) els.modal.classList.add("hidden");
    });

    els.btnExport.addEventListener("click", () => {
      const blob = new Blob([JSON.stringify(state.progress, null, 2)], { type: "application/json" });
      const a = document.createElement("a");
      a.href = URL.createObjectURL(blob);
      a.download = "pharma-qbank-progress.json";
      a.click();
    });

    els.btnImport.addEventListener("click", () => els.importFile.click());
    els.importFile.addEventListener("change", () => {
      const file = els.importFile.files?.[0];
      if (!file) return;
      const reader = new FileReader();
      reader.onload = () => {
        try {
          const parsed = JSON.parse(String(reader.result || "{}"));
          state.progress = {
            answers: parsed.answers || {},
            bookmarks: parsed.bookmarks || {},
            notes: parsed.notes || {},
            lastId: parsed.lastId || 1,
          };
          saveProgress();
          els.modal.classList.add("hidden");
          applyFilter(state.progress.lastId);
        } catch (_) {
          alert("Invalid progress JSON file.");
        }
      };
      reader.readAsText(file);
      els.importFile.value = "";
    });

    els.btnResetResponses.addEventListener("click", () => {
      if (!confirm("Reset all solved responses? (Your bookmarks and notes will be kept.)")) return;
      state.progress.answers = {};
      state.examPicks = {};
      state.examSubmitted = false;
      saveProgress();
      els.modal.classList.add("hidden");
      applyFilter(currentQuestion()?.id);
    });

    els.btnClearProgress.addEventListener("click", () => {
      if (!confirm("Reset ALL answers, bookmarks, and notes?")) return;
      state.progress = { answers: {}, bookmarks: {}, notes: {}, lastId: 1 };
      state.examPicks = {};
      state.examSubmitted = false;
      saveProgress();
      els.modal.classList.add("hidden");
      applyFilter();
    });

    // Keyboard shortcuts
    document.addEventListener("keydown", (e) => {
      if (e.target.tagName === "TEXTAREA" || e.target.tagName === "INPUT") return;
      if (e.key === "Escape") {
        closeLightbox();
        els.modal.classList.add("hidden");
        return;
      }
      const k = e.key.toLowerCase();
      if (k === "a" || k === "1") pickOption("A");
      else if (k === "b" || k === "2") pickOption("B");
      else if (k === "c" || k === "3") pickOption("C");
      else if (k === "d" || k === "4") pickOption("D");
      else if (e.key === "ArrowLeft") els.btnPrev.click();
      else if (e.key === "ArrowRight") els.btnNext.click();
      else if (k === "e") toggleExplanation();
      else if (k === "s") els.btnBookmark.click();
      else if (k === "z") {
        const q = currentQuestion();
        if (q) openLightbox(resolveImageSrc(q.q_img));
      } else if (k === "g") {
        els.sidebar.classList.toggle("collapsed");
      }
    });
  }

  async function init() {
    bindEvents();
    if (window.innerWidth <= 820) els.sidebar.classList.add("collapsed");

    await loadProgress();
    try {
      let data;
      if (IS_STANDALONE) {
        data = window.QBANK_DATA;
      } else {
        const res = await fetch("/data/questions.json");
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        data = await res.json();
      }
      state.allQuestions = data.questions || [];
      els.loading.classList.add("hidden");
      applyFilter(state.progress.lastId);
    } catch (err) {
      els.loading.innerHTML = `
        <h2>Questions not extracted yet</h2>
        <p class="muted">Run <code>uv run pharma-extract</code> inside the repository first, then reload this page.</p>
        <p class="muted">${err.message}</p>
      `;
    }
  }

  init();
})();
