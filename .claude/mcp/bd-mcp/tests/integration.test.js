// integration.test.js — drives the bd-mcp server end-to-end against a
// real Beads installation in a fresh temp directory.
//
// Test layout:
//   - lifecycle: create -> show -> update -> add comment -> close
//   - list tools: list_tasks (filters), get_ready, get_blocked, list_labels
//   - dependency tools: add_dep, list_deps
//   - doc tools: doc_write (main + named) -> doc_read -> versioning
//   - QA gate: qa_enter -> qa_status (entered) -> qa_approve -> qa_status (approved)
//   - QA gate: qa_block -> qa_status (blocked) -> labels are correct
//   - error paths: bad task id -> actionable message; missing task -> hint
//
// The bdmcptest helper symlinks the project's qa-gate.sh into the temp
// tree's .claude/scripts/, so the QA tests exercise the real shell helper
// (with its memory-write + iteration-counter wipe side effects).

import test from 'node:test';
import assert from 'node:assert/strict';

import { buildServer } from '../src/server.js';
import { createTempBeadsRepo, expectOk, expectErr, callTool } from './helpers.js';

// One server is enough across tests — it has no per-call state, just
// shells out to bd in whatever cwd we pass. Each test creates its own
// temp repo so tests don't interfere with each other.
const server = buildServer();

test('lifecycle: create -> show -> update -> add comment -> close', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const created = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'Test the bd-mcp server',
            priority: '1',
            labels: ['backend', 'qa-pending'],
            description: 'Smoke test the create flow.',
            cwd: ctx.cwd,
        }),
        'create_task should return data',
    );
    assert.ok(created.id, 'created task should have an id');
    const tid = created.id;

    const shown = expectOk(
        await callTool(server, 'bd_show_task', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(shown.id, tid);
    assert.equal(shown.status, 'open');
    assert.ok(Array.isArray(shown.labels) && shown.labels.includes('backend'));

    const updated = expectOk(
        await callTool(server, 'bd_update_task', {
            task_id: tid,
            status: 'in_progress',
            notes: 'Started work.',
            add_labels: ['in-progress-marker'],
            cwd: ctx.cwd,
        }),
    );
    assert.equal(updated.status, 'in_progress');
    assert.ok(updated.labels.includes('in-progress-marker'));

    expectOk(
        await callTool(server, 'bd_add_comment', {
            task_id: tid,
            body: 'A useful comment.',
            metadata: { kind: 'progress', sequence: 1 },
            cwd: ctx.cwd,
        }),
    );

    const comments = expectOk(
        await callTool(server, 'bd_list_comments', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.ok(comments.comments.length >= 1, 'should see at least the new comment');
    const ourComment = comments.comments.find((c) => (c.text || '').includes('A useful comment'));
    assert.ok(ourComment, 'comment text should round-trip');
    assert.match(ourComment.text, /BD-MCP-META/, 'metadata should be embedded as a sentinel comment');

    const closed = expectOk(
        await callTool(server, 'bd_close_task', {
            task_ids: [tid],
            reason: 'Test done',
            cwd: ctx.cwd,
        }),
    );
    assert.ok(closed != null, 'close should return some payload');

    // After closing, show should still resolve (Beads stores closed issues).
    const shownAfter = expectOk(
        await callTool(server, 'bd_show_task', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(shownAfter.status, 'closed');
});

test('list_tasks: filters by status and labels (AND/OR)', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const a = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'A: backend task',
            labels: ['backend'],
            cwd: ctx.cwd,
        }),
    ).id;
    const b = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'B: frontend task',
            labels: ['frontend'],
            cwd: ctx.cwd,
        }),
    ).id;
    const c = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'C: backend + qa-pending',
            labels: ['backend', 'qa-pending'],
            cwd: ctx.cwd,
        }),
    ).id;

    const allBackend = expectOk(
        await callTool(server, 'bd_list_tasks', {
            labels_all: ['backend'],
            cwd: ctx.cwd,
        }),
    );
    const ids = allBackend.map((x) => x.id).sort();
    assert.deepEqual(ids, [a, c].sort(), 'AND filter should return only backend-labelled tasks');

    const eitherDomain = expectOk(
        await callTool(server, 'bd_list_tasks', {
            labels_any: ['frontend', 'backend'],
            cwd: ctx.cwd,
        }),
    );
    assert.equal(eitherDomain.length, 3, 'OR filter should match all three');

    const bAndQa = expectOk(
        await callTool(server, 'bd_list_tasks', {
            labels_all: ['backend', 'qa-pending'],
            cwd: ctx.cwd,
        }),
    );
    assert.equal(bAndQa.length, 1, 'AND across two labels should narrow to C');
    assert.equal(bAndQa[0].id, c);
});

test('epic + children: bd_create_epic creates and links', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const result = expectOk(
        await callTool(server, 'bd_create_epic', {
            title: 'Epic X',
            children: [
                { title: 'Child 1', priority: '1' },
                { title: 'Child 2', labels: ['frontend'] },
            ],
            cwd: ctx.cwd,
        }),
    );
    assert.ok(result.epic, 'epic should be returned');
    assert.equal(result.children.length, 2, 'two children should be created');
    const epicId = result.epic.id;

    const kids = expectOk(
        await callTool(server, 'bd_list_tasks', {
            parent: epicId,
            cwd: ctx.cwd,
        }),
    );
    assert.equal(kids.length, 2, 'list with parent= should find both children');
});

test('add_label / remove_label / list_labels are idempotent', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const tid = expectOk(
        await callTool(server, 'bd_create_task', { title: 'L', cwd: ctx.cwd }),
    ).id;

    expectOk(await callTool(server, 'bd_add_label', { task_ids: [tid], label: 'foo', cwd: ctx.cwd }));
    expectOk(await callTool(server, 'bd_add_label', { task_ids: [tid], label: 'foo', cwd: ctx.cwd })); // idempotent
    expectOk(await callTool(server, 'bd_add_label', { task_ids: [tid], label: 'bar', cwd: ctx.cwd }));

    const labels = expectOk(
        await callTool(server, 'bd_list_labels', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.ok(labels.labels.includes('foo'));
    assert.ok(labels.labels.includes('bar'));

    expectOk(await callTool(server, 'bd_remove_label', { task_ids: [tid], label: 'foo', cwd: ctx.cwd }));
    expectOk(await callTool(server, 'bd_remove_label', { task_ids: [tid], label: 'foo', cwd: ctx.cwd })); // idempotent

    const labelsAfter = expectOk(
        await callTool(server, 'bd_list_labels', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.ok(!labelsAfter.labels.includes('foo'));
    assert.ok(labelsAfter.labels.includes('bar'));
});

test('dependencies: add_dep -> get_blocked -> list_deps', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const blocker = expectOk(
        await callTool(server, 'bd_create_task', { title: 'Blocker', cwd: ctx.cwd }),
    ).id;
    const dependent = expectOk(
        await callTool(server, 'bd_create_task', { title: 'Dependent', cwd: ctx.cwd }),
    ).id;

    expectOk(
        await callTool(server, 'bd_add_dep', {
            blocker,
            dependent,
            kind: 'blocks',
            cwd: ctx.cwd,
        }),
    );

    const blocked = expectOk(
        await callTool(server, 'bd_get_blocked', { cwd: ctx.cwd }),
    );
    const blockedIds = blocked.map((x) => x.id);
    assert.ok(blockedIds.includes(dependent), `${dependent} should be blocked`);

    const deps = expectOk(
        await callTool(server, 'bd_list_deps', { task_id: dependent, cwd: ctx.cwd }),
    );
    assert.ok(Array.isArray(deps.dependencies));
    const linkToBlocker = deps.dependencies.find((d) => d.id === blocker);
    assert.ok(
        linkToBlocker,
        `dependent ${dependent} should list blocker ${blocker} in dependencies (got: ${JSON.stringify(deps.dependencies)})`,
    );

    // The blocker side: reverse-ref via `dependents`.
    const blockerDeps = expectOk(
        await callTool(server, 'bd_list_deps', { task_id: blocker, cwd: ctx.cwd }),
    );
    assert.ok(
        blockerDeps.dependents.find((d) => d.id === dependent),
        `blocker ${blocker} should list ${dependent} in dependents`,
    );

    // Once we close the blocker, dependent should appear in ready.
    expectOk(
        await callTool(server, 'bd_close_task', {
            task_ids: [blocker],
            reason: 'done',
            cwd: ctx.cwd,
        }),
    );
    const ready = expectOk(await callTool(server, 'bd_get_ready', { cwd: ctx.cwd }));
    const readyIds = ready.map((x) => x.id);
    assert.ok(readyIds.includes(dependent), 'closing the blocker should free the dependent');
});

test('doc tools: main doc lives in notes; named docs version up', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const tid = expectOk(
        await callTool(server, 'bd_create_task', { title: 'Doc Test', cwd: ctx.cwd }),
    ).id;

    // Write main.
    expectOk(
        await callTool(server, 'bd_doc_write', {
            task_id: tid,
            content: '# Spec\n\nThe spec body.',
            cwd: ctx.cwd,
        }),
    );

    const main = expectOk(
        await callTool(server, 'bd_doc_read', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(main.name, 'main');
    assert.match(main.content, /spec body/i);
    assert.equal(main.storage, 'notes');

    // Write named doc twice -> versioning.
    expectOk(
        await callTool(server, 'bd_doc_write', {
            task_id: tid,
            name: 'qa-plan',
            content: 'v1 plan',
            cwd: ctx.cwd,
        }),
    );
    expectOk(
        await callTool(server, 'bd_doc_write', {
            task_id: tid,
            name: 'qa-plan',
            content: 'v2 plan',
            cwd: ctx.cwd,
        }),
    );

    const latest = expectOk(
        await callTool(server, 'bd_doc_read', { task_id: tid, name: 'qa-plan', cwd: ctx.cwd }),
    );
    assert.equal(latest.version, 2);
    assert.match(latest.content, /v2 plan/);

    const v1 = expectOk(
        await callTool(server, 'bd_doc_read', {
            task_id: tid,
            name: 'qa-plan',
            version: 1,
            cwd: ctx.cwd,
        }),
    );
    assert.equal(v1.version, 1);
    assert.match(v1.content, /v1 plan/);

    const list = expectOk(
        await callTool(server, 'bd_doc_read', {
            task_id: tid,
            list_only: true,
            cwd: ctx.cwd,
        }),
    );
    assert.ok(list.docs.find((d) => d.name === 'main'));
    assert.ok(list.docs.find((d) => d.name === 'qa-plan' && d.version === 2));
});

test('qa-gate lifecycle: enter -> status (entered) -> approve -> status (approved)', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const tid = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'QA gate task',
            labels: ['qa-pending'],
            cwd: ctx.cwd,
        }),
    ).id;

    const initialStatus = expectOk(
        await callTool(server, 'bd_qa_status', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(initialStatus.status, 'not-entered');

    expectOk(await callTool(server, 'bd_qa_enter', { task_id: tid, cwd: ctx.cwd }));
    const enteredStatus = expectOk(
        await callTool(server, 'bd_qa_status', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(enteredStatus.status, 'entered');

    // Idempotent re-enter.
    expectOk(await callTool(server, 'bd_qa_enter', { task_id: tid, cwd: ctx.cwd }));

    expectOk(
        await callTool(server, 'bd_qa_approve', {
            task_id: tid,
            summary: 'All tests green; reviewed by me.',
            cwd: ctx.cwd,
        }),
    );
    const approved = expectOk(
        await callTool(server, 'bd_qa_status', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(approved.status, 'approved');

    // Approve is idempotent.
    expectOk(
        await callTool(server, 'bd_qa_approve', {
            task_id: tid,
            summary: 're-approve',
            cwd: ctx.cwd,
        }),
    );

    // Verify the labels actually transitioned.
    const labels = expectOk(
        await callTool(server, 'bd_list_labels', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.ok(labels.labels.includes('qa-approved'));
    assert.ok(!labels.labels.includes('qa-gate-entered'));
    assert.ok(!labels.labels.includes('qa-pending'));
});

test('qa-gate: block path adds qa-blocked and keeps qa-gate-entered', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const tid = expectOk(
        await callTool(server, 'bd_create_task', {
            title: 'QA block test',
            labels: ['qa-pending'],
            cwd: ctx.cwd,
        }),
    ).id;

    expectOk(await callTool(server, 'bd_qa_enter', { task_id: tid, cwd: ctx.cwd }));
    expectOk(
        await callTool(server, 'bd_qa_block', {
            task_id: tid,
            reason: 'Failing tests in module Y',
            cwd: ctx.cwd,
        }),
    );

    const status = expectOk(
        await callTool(server, 'bd_qa_status', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.equal(status.status, 'blocked');

    const labels = expectOk(
        await callTool(server, 'bd_list_labels', { task_id: tid, cwd: ctx.cwd }),
    );
    assert.ok(labels.labels.includes('qa-blocked'));
    assert.ok(labels.labels.includes('qa-gate-entered'), 'gate-entered should be preserved on block');
});

test('error paths: bad ids and missing tasks return actionable hints', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());

    const badIdResult = await callTool(server, 'bd_show_task', {
        task_id: 'not a real id with spaces',
        cwd: ctx.cwd,
    });
    const badIdText = expectErr(badIdResult, 'invalid id should be rejected');
    assert.match(badIdText, /invalid characters|hint/i);

    const missingResult = await callTool(server, 'bd_show_task', {
        task_id: 'tst-9999999',
        cwd: ctx.cwd,
    });
    const missingText = expectErr(missingResult, 'missing id should be rejected');
    assert.match(missingText, /not found|hint/i);
    assert.match(missingText, /bd_list_tasks|bd_get_ready/, 'hint should mention list/ready helpers');
});

test('safety: set_labels conflicts with add_labels return a clear error', async (t) => {
    const ctx = await createTempBeadsRepo();
    t.after(() => ctx.cleanup());
    const tid = expectOk(
        await callTool(server, 'bd_create_task', { title: 'guard', cwd: ctx.cwd }),
    ).id;
    const r = await callTool(server, 'bd_update_task', {
        task_id: tid,
        set_labels: ['x'],
        add_labels: ['y'],
        cwd: ctx.cwd,
    });
    const text = expectErr(r);
    assert.match(text, /set_labels conflicts with add_labels/i);
});

test('all tools have annotations and inputSchema set', async () => {
    const tools = server._registeredTools || {};
    const names = Object.keys(tools);
    assert.ok(names.length >= 17, `expected >=17 tools, got ${names.length}: ${names.join(', ')}`);
    for (const name of names) {
        const t = tools[name];
        assert.ok(t.annotations, `${name}: annotations must be present`);
        assert.equal(typeof t.annotations.openWorldHint, 'boolean', `${name}: openWorldHint should be set`);
        assert.ok(t.inputSchema, `${name}: inputSchema must be present`);
        assert.ok(t.description && t.description.length > 20, `${name}: description must be informative`);
    }
});
