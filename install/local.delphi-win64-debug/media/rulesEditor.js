'use strict';

/*
 * Webview UI for the exceptionRules editor.
 *
 * Design intent:
 *  - the evaluation ORDER is semantic (first match wins), so every rule shows
 *    its position and can be moved with the up/down buttons;
 *  - match criteria and the action live in two visually separate panes so it is
 *    never ambiguous which is which;
 *  - validation runs on every keystroke using the same rules.js module the
 *    extension host uses before writing the file.
 */

(function () {
  var vscode = acquireVsCodeApi();
  var R = window.DelphiRules;
  var state = window.INITIAL_STATE || { rules: [], readOnly: false };

  /*
   * How to name the file being edited. The rules can live in a launch
   * configuration or in the machine-wide shared file, and telling the user to
   * "paste this into launch.json" while they are editing the shared file would
   * be simply wrong.
   */
  function fileNoun() {
    return state.fileNoun || 'launch.json';
  }

  // A draft keeps every field as text so half-typed input is not thrown away.
  function ruleToDraft(rule) {
    var draft = { action: rule.action === undefined ? 'break' : rule.action, extra: {} };
    R.MATCH_FIELDS.forEach(function (field) {
      var value = rule[field.name];
      if (value === undefined) {
        draft[field.name] = '';
      } else if (field.kind === 'names') {
        draft[field.name] = R.namesToText(value);
      } else if (field.kind === 'codes') {
        draft[field.name] = R.codesToText(value);
      } else {
        draft[field.name] = String(value);
      }
    });
    Object.keys(rule).forEach(function (key) {
      if (R.FIELD_ORDER.indexOf(key) === -1) draft.extra[key] = rule[key];
    });
    return draft;
  }

  function draftToRule(draft) {
    var rule = {};
    R.MATCH_FIELDS.forEach(function (field) {
      var text = (draft[field.name] || '').trim();
      if (text === '') return;
      if (field.kind === 'names') {
        rule[field.name] = R.textToNames(text);
      } else if (field.kind === 'codes') {
        rule[field.name] = R.textToCodes(text);
      } else if (field.kind === 'integer') {
        // Keep non-numeric text as-is so validation can complain about it.
        rule[field.name] = /^-?\d+$/.test(text) ? Number(text) : text;
      } else {
        rule[field.name] = text;
      }
    });
    rule.action = draft.action;
    Object.keys(draft.extra || {}).forEach(function (key) { rule[key] = draft.extra[key]; });
    return R.normalizeRule(rule);
  }

  var drafts = (state.rules || []).map(ruleToDraft);
  var problems = [];
  var dirty = false;
  var statusText = '';

  function currentRules() {
    return drafts.map(draftToRule);
  }

  function revalidate() {
    problems = R.validateRules(currentRules());
  }

  function problemsFor(index, fieldName) {
    return problems.filter(function (problem) {
      return problem.index === index && problem.field === fieldName;
    });
  }

  function element(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  function button(label, title, onClick, options) {
    var className = options && options.className !== undefined ? options.className : 'icon';
    var node = element('button', className, label);
    node.title = title;
    node.disabled = Boolean(options && options.disabled);
    node.addEventListener('click', onClick);
    return node;
  }

  function markDirty() {
    dirty = true;
    statusText = 'Unsaved changes';
  }

  function moveRule(from, to) {
    if (to < 0 || to >= drafts.length) return;
    var moved = drafts.splice(from, 1)[0];
    drafts.splice(to, 0, moved);
    markDirty();
    render();
  }

  function buildFieldEditor(draft, index, field) {
    var wrapper = element('div');
    var label = element('label', undefined, field.label);
    var input = document.createElement('input');
    input.type = 'text';
    input.value = draft[field.name] || '';
    var placeholder = 'any';
    if (field.kind === 'integer') placeholder = 'line number';
    else if (field.kind === 'codes') placeholder = 'any (e.g. 0xC0000005)';
    input.placeholder = placeholder;
    input.title = field.hint;
    input.setAttribute('aria-label', field.label + '. ' + field.hint);
    input.addEventListener('input', function () {
      draft[field.name] = input.value;
      markDirty();
      refreshValidation();
    });
    wrapper.appendChild(label);
    wrapper.appendChild(input);
    var errorHost = element('div', 'field-error');
    errorHost.dataset.errorFor = index + ':' + field.name;
    wrapper.appendChild(errorHost);
    input.dataset.inputFor = index + ':' + field.name;
    return wrapper;
  }

  function buildActionPane(draft, index) {
    var pane = element('div', 'pane action');
    pane.appendChild(element('div', 'pane-title', 'Then - action'));
    var select = document.createElement('select');
    select.setAttribute('aria-label', 'Action for rule ' + (index + 1));
    R.RULE_ACTIONS.forEach(function (action) {
      var option = document.createElement('option');
      option.value = action;
      option.textContent = action;
      select.appendChild(option);
    });
    if (R.RULE_ACTIONS.indexOf(draft.action) === -1) {
      var custom = document.createElement('option');
      custom.value = draft.action;
      custom.textContent = draft.action + ' (invalid)';
      select.appendChild(custom);
    }
    select.value = draft.action;
    select.dataset.inputFor = index + ':action';
    var help = element('div', 'action-help', R.ACTION_DESCRIPTIONS[draft.action] || '');
    select.addEventListener('change', function () {
      draft.action = select.value;
      help.textContent = R.ACTION_DESCRIPTIONS[draft.action] || '';
      markDirty();
      refreshValidation();
    });
    pane.appendChild(select);
    var errorHost = element('div', 'field-error');
    errorHost.dataset.errorFor = index + ':action';
    pane.appendChild(errorHost);
    pane.appendChild(help);
    return pane;
  }

  function buildRuleCard(draft, index) {
    var card = element('div', 'rule');
    card.dataset.ruleIndex = String(index);

    var header = element('div', 'rule-header');
    header.appendChild(element('span', 'order-badge', '#' + (index + 1)));
    var summary = element('span', 'rule-summary', R.describeRule(draftToRule(draft)));
    summary.dataset.summaryFor = String(index);
    header.appendChild(summary);
    header.appendChild(button('↑', 'Move up (evaluated earlier)', function () { moveRule(index, index - 1); },
      { disabled: index === 0 || state.readOnly }));
    header.appendChild(button('↓', 'Move down (evaluated later)', function () { moveRule(index, index + 1); },
      { disabled: index === drafts.length - 1 || state.readOnly }));
    header.appendChild(button('⧉', 'Duplicate this rule', function () {
      drafts.splice(index + 1, 0, JSON.parse(JSON.stringify(draft)));
      markDirty();
      render();
    }, { disabled: state.readOnly }));
    header.appendChild(button('✕', 'Delete this rule', function () {
      drafts.splice(index, 1);
      markDirty();
      render();
    }, { disabled: state.readOnly }));
    card.appendChild(header);

    var body = element('div', 'rule-body');
    var matchPane = element('div', 'pane match');
    matchPane.appendChild(element('div', 'pane-title', 'Match if - all criteria (blank = any)'));
    var fields = element('div', 'fields');
    R.MATCH_FIELDS.forEach(function (field) {
      fields.appendChild(buildFieldEditor(draft, index, field));
    });
    matchPane.appendChild(fields);
    body.appendChild(matchPane);
    body.appendChild(buildActionPane(draft, index));
    card.appendChild(body);

    var unknownKeys = Object.keys(draft.extra || {});
    if (unknownKeys.length) {
      var warning = element('div', 'problems',
        'Unknown field(s) kept from ' + fileNoun() + ': ' + unknownKeys.join(', ') +
        '. Remove them before saving.');
      var removeButton = button('Remove unknown fields', 'Drop the unrecognised fields from this rule',
        function () {
          draft.extra = {};
          markDirty();
          render();
        }, { className: '', disabled: state.readOnly });
      warning.appendChild(document.createElement('br'));
      warning.appendChild(removeButton);
      card.appendChild(warning);
    }
    return card;
  }

  function refreshValidation() {
    revalidate();
    applyValidationToDom();
  }

  // Renders whatever is currently in `problems`. Kept separate from
  // revalidate() so problems reported by the extension host (which validates
  // again just before writing) are not immediately overwritten.
  function applyValidationToDom() {
    document.querySelectorAll('[data-error-for]').forEach(function (host) {
      var key = host.dataset.errorFor.split(':');
      var messages = problemsFor(Number(key[0]), key[1]);
      host.textContent = messages.map(function (problem) { return problem.message; }).join('; ');
    });
    document.querySelectorAll('[data-input-for]').forEach(function (input) {
      var key = input.dataset.inputFor.split(':');
      var invalid = problemsFor(Number(key[0]), key[1]).length > 0;
      input.classList.toggle('invalid', invalid);
    });
    document.querySelectorAll('[data-summary-for]').forEach(function (node) {
      var index = Number(node.dataset.summaryFor);
      node.textContent = R.describeRule(draftToRule(drafts[index]));
      var card = document.querySelector('[data-rule-index="' + index + '"]');
      if (card) {
        card.classList.toggle('invalid', problems.some(function (problem) { return problem.index === index; }));
      }
    });
    updateFooter();
    updateToolbar();
  }

  function updateToolbar() {
    var saveButton = document.getElementById('save-button');
    if (saveButton) saveButton.disabled = state.readOnly || problems.length > 0;
    var status = document.getElementById('status');
    if (status) {
      status.textContent = problems.length
        ? problems.length + ' problem(s) - fix before saving'
        : statusText;
    }
  }

  function updateFooter() {
    var host = document.getElementById('problems');
    if (!host) return;
    host.textContent = '';
    if (!problems.length) return;
    var box = element('div', 'problems');
    box.appendChild(element('strong', undefined, 'These problems block saving:'));
    var list = document.createElement('ul');
    problems.forEach(function (problem) {
      var where = problem.index >= 0 ? 'Rule #' + (problem.index + 1) : 'Rules';
      var what = problem.field ? ' - ' + problem.field : '';
      list.appendChild(element('li', undefined, where + what + ': ' + problem.message));
    });
    box.appendChild(list);
    host.appendChild(box);

    var preview = document.getElementById('preview-body');
    if (preview) preview.textContent = R.serializeRules(currentRules(), '', '\n');
  }

  function render() {
    revalidate();
    var app = document.getElementById('app');
    app.textContent = '';

    app.appendChild(element('h1', undefined, 'Exception rules — ' + (state.configurationName || '')));
    app.appendChild(element('div', 'subtitle', state.documentLabel || ''));

    var banner = element('div', 'banner',
      'Rules are evaluated top-down and the FIRST match wins. Within one rule every filled-in ' +
      'criterion must match (blank fields match anything). If no rule matches, the exception ' +
      'filters in the BREAKPOINTS view decide.');
    app.appendChild(banner);

    if (state.readOnly) {
      var warning = element('div', 'banner warning',
        (state.readOnlyReason || 'This editor is read-only.') +
        ' Use "Copy JSON" and paste the rules into ' + fileNoun() + ' manually.');
      app.appendChild(warning);
    }

    var toolbar = element('div', 'toolbar');
    var addButton = button('+ Add rule', 'Append a new rule at the end', function () {
      drafts.push(ruleToDraft({ action: 'break' }));
      markDirty();
      render();
    }, { className: '', disabled: state.readOnly });
    toolbar.appendChild(addButton);
    toolbar.appendChild(element('span', 'spacer'));
    var status = element('span', 'status', statusText);
    status.id = 'status';
    toolbar.appendChild(status);
    toolbar.appendChild(button('Copy JSON', 'Copy the exceptionRules array to the clipboard', function () {
      vscode.postMessage({ type: 'copy', text: R.serializeRules(currentRules(), '', '\n') });
    }, { className: '' }));
    var saveButton = button(state.saveLabel || 'Save to launch.json',
      state.saveTitle || 'Write these rules back into the launch configuration',
      function () {
        vscode.postMessage({ type: 'save', rules: currentRules() });
      }, { className: 'primary', disabled: state.readOnly });
    saveButton.id = 'save-button';
    toolbar.appendChild(saveButton);
    app.appendChild(toolbar);

    if (!drafts.length) {
      app.appendChild(element('div', 'empty',
        'No exception rules yet. Add one, or leave the list empty to keep using the plain exception filters.'));
    } else {
      drafts.forEach(function (draft, index) {
        app.appendChild(buildRuleCard(draft, index));
      });
    }

    var problemsHost = element('div');
    problemsHost.id = 'problems';
    app.appendChild(problemsHost);

    var preview = element('details', 'preview');
    var previewSummary = document.createElement('summary');
    previewSummary.textContent = 'Preview the JSON that will be written';
    preview.appendChild(previewSummary);
    var pre = document.createElement('pre');
    pre.id = 'preview-body';
    pre.textContent = R.serializeRules(currentRules(), '', '\n');
    preview.appendChild(pre);
    app.appendChild(preview);

    refreshValidation();
  }

  window.addEventListener('message', function (event) {
    var message = event.data;
    if (!message) return;
    if (message.type === 'saved') {
      dirty = false;
      statusText = 'Saved - review the ' + fileNoun() + ' editor that just opened';
      updateToolbar();
    } else if (message.type === 'saveFailed') {
      statusText = 'Save failed: ' + message.message;
      updateToolbar();
    } else if (message.type === 'saveRejected') {
      problems = message.problems || [];
      statusText = 'The rules were rejected before writing';
      applyValidationToDom();
    }
  });

  render();
}());
