const PRIORITY_QUESTIONS = [
    { key: 'increase_revenue', group: 'Business Value / ROI', label: 'Increase revenue', points: 9, notePlaceholder: 'Expected revenue increase in SAR' },
    { key: 'reduce_cost', group: 'Business Value / ROI', label: 'Reduce cost, avoid penalties', points: 9, notePlaceholder: 'Expected cost decrease in SAR' },
    { key: 'increase_csat', group: 'Business Value / ROI', label: 'Increase CSAT', points: 4.5, notePlaceholder: 'How the change will increase CSAT' },
    { key: 'increase_eei', group: 'Business Value / ROI', label: 'EEI (Employee Experience Index)', points: 3, notePlaceholder: 'How the change will increase EEI' },
    { key: 'falak_process', group: 'Business Value / ROI', label: 'Critical process (Falak)', points: 4.5, notePlaceholder: 'Process name if documented in Falak' },
    { key: 'strategic_initiative', group: 'Strategic Fit', label: 'Align with strategic initiative', points: 10, notePlaceholder: 'Initiative name' },
    { key: 'align_scale', group: 'Strategic Fit', label: 'Align with SCALE', points: 10, notePlaceholder: 'SCALE objective' }
];

const DEPARTMENT_PRIORITY_POINTS = { Urgent: 20, High: 15, Medium: 10, Low: 0 };
const SIMPLICITY_POINTS = { 'Very Easy': 30, Easy: 24, Medium: 15, Complex: 0 };

function calculatePriorityScore(answers) {
    answers = answers || {};
    let score = 0;
    PRIORITY_QUESTIONS.forEach(q => {
        if (answers[q.key] && answers[q.key].yes) score += q.points;
    });
    score += DEPARTMENT_PRIORITY_POINTS[answers.department_priority] || 0;
    score += SIMPLICITY_POINTS[answers.simplicity] || 0;
    return Math.round(score * 10) / 10;
}
