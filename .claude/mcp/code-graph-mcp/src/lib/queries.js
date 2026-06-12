// queries.js — per-language tree-sitter query strings.
//
// Three queries per language, named consistently across languages so the
// indexer can run the same harness regardless of grammar:
//
//   defs    — symbol definitions. Captures @def.name for the identifier
//             and @def.kind from the syntactic shape (function/class/
//             method/const/etc.). Marks @def.export when the syntactic
//             form is export-visible.
//   calls   — call expressions. Captures @call.name (the callee
//             identifier).
//   imports — import / require statements. Captures @import.module
//             (the module path) and @import.name (each imported name).
//
// **Honest coverage**: these queries are pragmatic, not semantic. They
// catch direct lexical-shape definitions and calls. They DO NOT resolve:
//
//   - dynamic dispatch (obj[method](), Reflect.apply, eval)
//   - reflection / metaprogramming (Python __getattr__, Ruby
//     method_missing, decorators that rewrite, etc.)
//   - macro expansion (Rust macros, C-preprocessor) — visible only
//     post-expansion
//   - re-exports that rename (`export { foo as bar }` in TS)
//   - heredoc'd dispatch in shell scripts
//
// Consumers must treat dead_code() and impact_of() with that
// understanding. The tool descriptions and README repeat this
// limitation.

export const QUERIES = {
    // -----------------------------------------------------------------------
    // TypeScript / TSX
    // -----------------------------------------------------------------------
    typescript: {
        defs: `
            (function_declaration name: (identifier) @def.name) @def.node
            (class_declaration name: (type_identifier) @def.name) @def.node
            (method_definition name: (property_identifier) @def.name) @def.node
            (interface_declaration name: (type_identifier) @def.name) @def.node
            (type_alias_declaration name: (type_identifier) @def.name) @def.node
            (enum_declaration name: (identifier) @def.name) @def.node
            (variable_declarator name: (identifier) @def.name) @def.node
            (export_statement (function_declaration name: (identifier) @def.name) @def.node) @export
            (export_statement (class_declaration name: (type_identifier) @def.name) @def.node) @export
            (export_statement (interface_declaration name: (type_identifier) @def.name) @def.node) @export
            (export_statement (type_alias_declaration name: (type_identifier) @def.name) @def.node) @export
            (export_statement (enum_declaration name: (identifier) @def.name) @def.node) @export
            (export_statement (lexical_declaration (variable_declarator name: (identifier) @def.name) @def.node)) @export
            (export_statement (variable_declaration (variable_declarator name: (identifier) @def.name) @def.node)) @export
        `,
        calls: `
            (call_expression
                function: (identifier) @call.name)
            (call_expression
                function: (member_expression property: (property_identifier) @call.name))
            (new_expression
                constructor: (identifier) @call.name)
        `,
        imports: `
            (import_statement
                source: (string (string_fragment) @import.module))
        `,
    },

    // tsx is a separate grammar but the surface we query is identical.
    // Re-using the typescript query strings keeps the indexer simple.
    get tsx() { return this.typescript; },

    // -----------------------------------------------------------------------
    // JavaScript (and JSX — same grammar)
    // -----------------------------------------------------------------------
    javascript: {
        defs: `
            (function_declaration name: (identifier) @def.name) @def.node
            (class_declaration name: (identifier) @def.name) @def.node
            (method_definition name: (property_identifier) @def.name) @def.node
            (variable_declarator name: (identifier) @def.name) @def.node
            (export_statement (function_declaration name: (identifier) @def.name) @def.node) @export
            (export_statement (class_declaration name: (identifier) @def.name) @def.node) @export
            (export_statement (lexical_declaration (variable_declarator name: (identifier) @def.name) @def.node)) @export
            (export_statement (variable_declaration (variable_declarator name: (identifier) @def.name) @def.node)) @export
        `,
        calls: `
            (call_expression
                function: (identifier) @call.name)
            (call_expression
                function: (member_expression property: (property_identifier) @call.name))
            (new_expression
                constructor: (identifier) @call.name)
        `,
        imports: `
            (import_statement
                source: (string (string_fragment) @import.module))
            (call_expression
                function: (identifier) @_require (#eq? @_require "require")
                arguments: (arguments (string (string_fragment) @import.module)))
        `,
    },

    // -----------------------------------------------------------------------
    // Python
    // -----------------------------------------------------------------------
    python: {
        defs: `
            (function_definition name: (identifier) @def.name) @def.node
            (class_definition name: (identifier) @def.name) @def.node
            (assignment left: (identifier) @def.name) @def.node
        `,
        calls: `
            (call function: (identifier) @call.name)
            (call function: (attribute attribute: (identifier) @call.name))
        `,
        imports: `
            (import_statement name: (dotted_name) @import.module)
            (import_from_statement module_name: (dotted_name) @import.module)
        `,
    },

    // -----------------------------------------------------------------------
    // Go
    // -----------------------------------------------------------------------
    go: {
        defs: `
            (function_declaration name: (identifier) @def.name) @def.node
            (method_declaration name: (field_identifier) @def.name) @def.node
            (type_declaration (type_spec name: (type_identifier) @def.name)) @def.node
            (const_spec name: (identifier) @def.name) @def.node
            (var_spec name: (identifier) @def.name) @def.node
        `,
        calls: `
            (call_expression
                function: (identifier) @call.name)
            (call_expression
                function: (selector_expression field: (field_identifier) @call.name))
        `,
        imports: `
            (import_spec path: (interpreted_string_literal) @import.module)
        `,
    },

    // -----------------------------------------------------------------------
    // Rust
    // -----------------------------------------------------------------------
    rust: {
        defs: `
            (function_item name: (identifier) @def.name) @def.node
            (struct_item name: (type_identifier) @def.name) @def.node
            (enum_item name: (type_identifier) @def.name) @def.node
            (trait_item name: (type_identifier) @def.name) @def.node
            (impl_item type: (type_identifier) @def.name) @def.node
            (const_item name: (identifier) @def.name) @def.node
            (static_item name: (identifier) @def.name) @def.node
            (mod_item name: (identifier) @def.name) @def.node
        `,
        calls: `
            (call_expression
                function: (identifier) @call.name)
            (call_expression
                function: (scoped_identifier name: (identifier) @call.name))
            (call_expression
                function: (field_expression field: (field_identifier) @call.name))
            (macro_invocation
                macro: (identifier) @call.name)
        `,
        imports: `
            (use_declaration argument: (scoped_identifier) @import.module)
            (use_declaration argument: (identifier) @import.module)
            (use_declaration argument: (use_list) @import.module)
        `,
    },

    // -----------------------------------------------------------------------
    // Java
    // -----------------------------------------------------------------------
    java: {
        defs: `
            (class_declaration name: (identifier) @def.name) @def.node
            (interface_declaration name: (identifier) @def.name) @def.node
            (method_declaration name: (identifier) @def.name) @def.node
            (constructor_declaration name: (identifier) @def.name) @def.node
            (enum_declaration name: (identifier) @def.name) @def.node
        `,
        calls: `
            (method_invocation name: (identifier) @call.name)
            (object_creation_expression type: (type_identifier) @call.name)
        `,
        imports: `
            (import_declaration (scoped_identifier) @import.module)
            (import_declaration (identifier) @import.module)
        `,
    },

    // -----------------------------------------------------------------------
    // Ruby
    // -----------------------------------------------------------------------
    ruby: {
        defs: `
            (method name: (identifier) @def.name) @def.node
            (singleton_method name: (identifier) @def.name) @def.node
            (class name: (constant) @def.name) @def.node
            (module name: (constant) @def.name) @def.node
            (assignment left: (identifier) @def.name) @def.node
            (assignment left: (constant) @def.name) @def.node
        `,
        // `(method_call ...)` node was removed from tree-sitter-ruby
        // 0.23.x; only `(call ...)` remains. Adjust per the modern
        // grammar surface.
        calls: `
            (call method: (identifier) @call.name)
            (call method: (constant) @call.name)
        `,
        imports: `
            (call method: (identifier) @_m (#match? @_m "^(require|require_relative|load|autoload)$")
                arguments: (argument_list (string (string_content) @import.module)))
        `,
    },

    // -----------------------------------------------------------------------
    // PHP
    // -----------------------------------------------------------------------
    php: {
        defs: `
            (function_definition name: (name) @def.name) @def.node
            (method_declaration name: (name) @def.name) @def.node
            (class_declaration name: (name) @def.name) @def.node
            (interface_declaration name: (name) @def.name) @def.node
            (trait_declaration name: (name) @def.name) @def.node
        `,
        calls: `
            (function_call_expression function: (name) @call.name)
            (member_call_expression name: (name) @call.name)
            (object_creation_expression (name) @call.name)
        `,
        imports: `
            (namespace_use_clause (qualified_name) @import.module)
            (namespace_use_clause (name) @import.module)
            (include_expression (string) @import.module)
            (require_expression (string) @import.module)
        `,
    },

    // -----------------------------------------------------------------------
    // Bash
    // -----------------------------------------------------------------------
    bash: {
        defs: `
            (function_definition name: (word) @def.name) @def.node
            (variable_assignment name: (variable_name) @def.name) @def.node
        `,
        calls: `
            (command name: (command_name (word) @call.name))
        `,
        imports: `
            (command name: (command_name (word) @_w) (#match? @_w "^(source|\\\\.)$")
                argument: (word) @import.module)
        `,
    },
};

/**
 * For a given language id, return the kind label we should record for a
 * tree-sitter node that captured @def.node. The label feeds into the
 * `symbols.kind` column for richer queries. Mapping is best-effort —
 * unknown shapes record 'symbol'. This is read at indexer time from
 * the captured node's .type.
 */
export function kindFromNodeType(nodeType) {
    switch (nodeType) {
        case 'function_declaration':
        case 'function_definition':
        case 'function_item':
        case 'method':
        case 'method_definition':
        case 'method_declaration':
        case 'singleton_method':
        case 'constructor_declaration':
        case 'arrow_function':
            return 'function';
        case 'class_declaration':
        case 'class_definition':
        case 'class':
            return 'class';
        case 'interface_declaration':
            return 'interface';
        case 'type_alias_declaration':
            return 'type';
        case 'enum_declaration':
        case 'enum_item':
            return 'enum';
        case 'struct_item':
            return 'struct';
        case 'trait_item':
        case 'trait_declaration':
            return 'trait';
        case 'impl_item':
            return 'impl';
        case 'mod_item':
        case 'module':
            return 'module';
        case 'variable_declarator':
        case 'const_item':
        case 'static_item':
        case 'const_spec':
        case 'var_spec':
        case 'assignment':
        case 'variable_assignment':
            return 'variable';
        case 'type_declaration':
        case 'type_spec':
            return 'type';
        case 'namespace_use_clause':
            return 'use';
        default:
            return 'symbol';
    }
}
