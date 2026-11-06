let evaluatingDemand = null;
let onEvaluationSaved = null;

function ensureEvaluateModal() {
    if (document.getElementById('evalModal')) return;
    document.body.insertAdjacentHTML('beforeend', `
        <div id="evalModal" class="fixed inset-0 bg-slate-900/50 backdrop-blur-sm hidden items-center justify-center p-4 z-[60]">
            <div class="bg-white rounded-xl shadow-xl max-w-2xl w-full p-6 space-y-4 max-h-[90vh] overflow-y-auto">
                <div class="flex justify-between items-start gap-4 border-b border-slate-200 pb-3">
                    <div>
                        <h3 class="font-bold text-lg text-slate-900">Prioritization Checklist</h3>
                        <p id="evalDemandTitle" class="text-xs text-slate-500"></p>
                    </div>
                    <div class="text-right">
                        <div class="text-xs font-bold text-slate-500">Total Score</div>
                        <div class="text-2xl font-bold text-brand-purple"><span id="evalScore">0</span><span class="text-sm text-slate-400"> / 100</span></div>
                    </div>
                </div>

                <form id="evalForm" onsubmit="saveEvaluation(event)" class="space-y-4">
                    <div id="evalQuestions" class="space-y-3"></div>

                    <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                        <div>
                            <label class="block text-xs font-semibold text-slate-600 mb-1">Priority in Department</label>
                            <select id="evalDeptPriority" required onchange="updateEvaluationScore()" class="w-full px-3 py-2 border rounded-lg text-sm outline-none focus:ring-2 focus:ring-brand-purple bg-white"></select>
                            <p class="text-[11px] text-slate-400 mt-1">Urgent max 10%, High max 10%, Medium max 30% of department demands</p>
                        </div>
                        <div>
                            <label class="block text-xs font-semibold text-slate-600 mb-1">Implementation Simplicity</label>
                            <select id="evalSimplicity" required onchange="updateEvaluationScore()" class="w-full px-3 py-2 border rounded-lg text-sm outline-none focus:ring-2 focus:ring-brand-purple bg-white"></select>
                        </div>
                    </div>

                    <div class="flex justify-end space-x-2 pt-3 border-t border-slate-200">
                        <button type="button" onclick="closeEvaluateModal()" class="px-4 py-2 text-xs font-semibold border rounded-lg text-slate-600 hover:bg-slate-50">Cancel</button>
                        <button type="submit" id="evalSaveBtn" class="px-4 py-2 text-xs font-semibold bg-brand-purple hover:bg-brand-purple-hover text-white rounded-lg">Save Priority</button>
                    </div>
                </form>
            </div>
        </div>
    `);
}

function evaluationOptionsHtml(pointsMap) {
    return `<option value="">Select...</option>` + Object.keys(pointsMap).map(level =>
        `<option value="${level}">${level} (${pointsMap[level]} pts)</option>`
    ).join('');
}

function openEvaluateModal(item, onSaved) {
    if (!item) return;
    ensureEvaluateModal();
    evaluatingDemand = item;
    onEvaluationSaved = onSaved || null;
    const answers = item.priority_answers || {};

    document.getElementById('evalDemandTitle').textContent =
        `${item.ref_id || 'REQ-' + String(item.id).padStart(3, '0')} — ${item.title || ''}`;

    let html = '';
    let lastGroup = '';
    PRIORITY_QUESTIONS.forEach(q => {
        if (q.group !== lastGroup) {
            html += `<h4 class="text-xs font-bold text-slate-500 uppercase tracking-wider pt-2">${q.group}</h4>`;
            lastGroup = q.group;
        }
        html += `
            <div class="border border-slate-200 rounded-lg p-3 space-y-2">
                <div class="flex justify-between items-center gap-3">
                    <span class="text-sm font-semibold text-slate-800">${q.label} <span class="text-xs font-normal text-slate-400">(${q.points} pts)</span></span>
                    <div class="flex gap-4 text-xs font-semibold text-slate-700">
                        <label class="flex items-center gap-1"><input type="radio" name="q-${q.key}" value="yes" onchange="updateEvaluationScore()"> Yes</label>
                        <label class="flex items-center gap-1"><input type="radio" name="q-${q.key}" value="no" onchange="updateEvaluationScore()"> No</label>
                    </div>
                </div>
                <input type="text" id="note-${q.key}" placeholder="${q.notePlaceholder}" class="w-full px-3 py-1.5 border rounded-lg text-xs outline-none focus:ring-2 focus:ring-brand-purple">
            </div>
        `;
    });
    document.getElementById('evalQuestions').innerHTML = html;

    PRIORITY_QUESTIONS.forEach(q => {
        const answer = answers[q.key] || {};
        document.querySelector(`input[name="q-${q.key}"][value="${answer.yes ? 'yes' : 'no'}"]`).checked = true;
        document.getElementById(`note-${q.key}`).value = answer.note || '';
    });
    document.getElementById('evalDeptPriority').innerHTML = evaluationOptionsHtml(DEPARTMENT_PRIORITY_POINTS);
    document.getElementById('evalDeptPriority').value = answers.department_priority || '';
    document.getElementById('evalSimplicity').innerHTML = evaluationOptionsHtml(SIMPLICITY_POINTS);
    document.getElementById('evalSimplicity').value = answers.simplicity || '';

    updateEvaluationScore();
    document.getElementById('evalModal').classList.remove('hidden');
    document.getElementById('evalModal').classList.add('flex');
}

function closeEvaluateModal() {
    document.getElementById('evalModal').classList.add('hidden');
    document.getElementById('evalModal').classList.remove('flex');
    evaluatingDemand = null;
    onEvaluationSaved = null;
}

function readEvaluationAnswers() {
    const answers = {};
    PRIORITY_QUESTIONS.forEach(q => {
        const checked = document.querySelector(`input[name="q-${q.key}"]:checked`);
        answers[q.key] = {
            yes: !!checked && checked.value === 'yes',
            note: document.getElementById(`note-${q.key}`).value.trim()
        };
    });
    answers.department_priority = document.getElementById('evalDeptPriority').value;
    answers.simplicity = document.getElementById('evalSimplicity').value;
    return answers;
}

function updateEvaluationScore() {
    document.getElementById('evalScore').textContent = calculatePriorityScore(readEvaluationAnswers());
}

async function saveEvaluation(e) {
    e.preventDefault();
    const answers = readEvaluationAnswers();
    const score = calculatePriorityScore(answers);
    const btn = document.getElementById('evalSaveBtn');
    btn.disabled = true;
    btn.textContent = 'Saving...';

    const { error } = await supabaseClient.from('demands').update({
        priority_answers: answers,
        priority_score: score,
        priority_evaluated_at: new Date().toISOString()
    }).eq('id', evaluatingDemand.id);

    btn.disabled = false;
    btn.textContent = 'Save Priority';

    if (error) {
        alert('Error saving priority: ' + error.message);
        return;
    }

    evaluatingDemand.priority_answers = answers;
    evaluatingDemand.priority_score = score;
    const callback = onEvaluationSaved;
    closeEvaluateModal();
    if (callback) await callback(score);
}
