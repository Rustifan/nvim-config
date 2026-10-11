// This helper prepares snippets and invokes Go asynchronously through Neovim's job.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"os"
	"os/exec"
	"path"
	"strconv"
	"strings"
)

type request struct {
	Code       string   `json:"code"`
	Source     string   `json:"source"`
	Filename   string   `json:"filename"`
	FirstLine  int      `json:"first_line"`
	Path       string   `json:"path"`
	Executable string   `json:"executable"`
	Args       []string `json:"args"`
	Goimports  string   `json:"goimports"`
}

type segment struct {
	code        string
	line        int
	declaration bool
}

func firstToken(code string) token.Token {
	set := token.NewFileSet()
	var scan scanner.Scanner
	scan.Init(set.AddFile("", -1, len(code)), []byte(code), nil, 0)
	_, kind, _ := scan.Scan()
	return kind
}

func declaration(code string) bool {
	kind := firstToken(code)
	if kind == token.IMPORT || kind == token.TYPE || kind == token.VAR || kind == token.CONST {
		return true
	}
	if kind != token.FUNC {
		return false
	}
	file, err := parser.ParseFile(token.NewFileSet(), "", "package main\n"+code, 0)
	return err == nil && len(file.Decls) == 1
}

func splitSnippet(code string, firstLine int) []segment {
	set := token.NewFileSet()
	file := set.AddFile("", -1, len(code))
	var scan scanner.Scanner
	scan.Init(file, []byte(code), nil, 0)
	var segments []segment
	start, depth := 0, 0
	boundary := false
	for {
		position, kind, _ := scan.Scan()
		if kind == token.EOF {
			break
		}
		if boundary {
			end := file.Offset(position)
			text := code[start:end]
			segments = append(segments, segment{text, firstLine + strings.Count(code[:start], "\n"), declaration(text)})
			start = end
			boundary = false
		}
		if kind == token.LPAREN || kind == token.LBRACE || kind == token.LBRACK {
			depth++
		}
		if kind == token.RPAREN || kind == token.RBRACE || kind == token.RBRACK {
			depth--
		}
		boundary = kind == token.SEMICOLON && depth == 0
	}
	if strings.TrimSpace(code[start:]) != "" {
		text := code[start:]
		segments = append(segments, segment{text, firstLine + strings.Count(code[:start], "\n"), declaration(text)})
	}
	return segments
}

func lineDirective(filename string, line int) string {
	return fmt.Sprintf("//line %s:%d\n", strings.ReplaceAll(filename, "\n", " "), line)
}

func hasMain(file *ast.File) bool {
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if ok && function.Recv == nil && function.Name.Name == "main" {
			return true
		}
	}
	return false
}

func snippetProgram(input request) (string, error) {
	parts := splitSnippet(input.Code, input.FirstLine)
	functions := false
	for _, part := range parts {
		functions = functions || (part.declaration && firstToken(part.code) == token.FUNC)
	}
	var declarations, statements strings.Builder
	for _, part := range parts {
		output := &statements
		if part.declaration && (functions || firstToken(part.code) == token.IMPORT) {
			output = &declarations
		}
		output.WriteString(lineDirective(input.Filename, part.line))
		output.WriteString(part.code)
		output.WriteByte('\n')
	}
	header := "package main\n" + declarations.String()
	file, err := parser.ParseFile(token.NewFileSet(), input.Filename, header, 0)
	if err != nil {
		return "", err
	}
	if hasMain(file) && statements.Len() > 0 {
		return "", errors.New("a Go snippet with func main() cannot also have top-level statements; put the calls inside main")
	}
	if hasMain(file) {
		return header, nil
	}
	return header + "func main() {\n" + statements.String() + "}\n", nil
}

func importName(spec *ast.ImportSpec) string {
	if spec.Name != nil {
		return spec.Name.Name
	}
	value, _ := strconv.Unquote(spec.Path.Value)
	name := path.Base(value)
	if len(name) <= 1 || name[0] != 'v' {
		return name
	}
	if _, err := strconv.Atoi(name[1:]); err == nil {
		return path.Base(path.Dir(value))
	}
	return name
}

func usedPackages(file *ast.File) map[string]bool {
	used := make(map[string]bool)
	ast.Inspect(file, func(node ast.Node) bool {
		selector, ok := node.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		name, ok := selector.X.(*ast.Ident)
		if ok && name.Obj == nil {
			used[name.Name] = true
		}
		return true
	})
	return used
}

func inheritedImports(input request, file *ast.File) string {
	used := usedPackages(file)
	present := make(map[string]bool)
	for _, spec := range file.Imports {
		present[spec.Path.Value] = true
		delete(used, importName(spec))
	}
	source, _ := parser.ParseFile(token.NewFileSet(), input.Filename, input.Source, parser.AllErrors)
	if source == nil {
		source = &ast.File{}
	}
	var imports strings.Builder
	for _, spec := range source.Imports {
		name := importName(spec)
		if present[spec.Path.Value] || name == "_" || (!used[name] && input.Goimports == "") {
			continue
		}
		imports.WriteString("import ")
		if spec.Name != nil {
			imports.WriteString(name + " ")
		}
		imports.WriteString(spec.Path.Value + "\n")
		present[spec.Path.Value] = true
		delete(used, name)
	}
	if used["fmt"] && !present[`"fmt"`] {
		imports.WriteString("import \"fmt\"\n")
	}
	return imports.String()
}

func prepare(input request) (string, error) {
	if firstToken(input.Code) == token.PACKAGE {
		code := lineDirective(input.Filename, input.FirstLine) + input.Code
		file, err := parser.ParseFile(token.NewFileSet(), input.Filename, code, 0)
		if err != nil {
			return "", err
		}
		if file.Name.Name != "main" || !hasMain(file) {
			return "", errors.New("whole Go files must be package main with func main(); select statements or a function plus its calls to test library code")
		}
		return code, nil
	}
	code, err := snippetProgram(input)
	if err != nil {
		return "", err
	}
	file, err := parser.ParseFile(token.NewFileSet(), input.Filename, code, 0)
	if err != nil {
		return "", err
	}
	return strings.Replace(code, "package main\n", "package main\n"+inheritedImports(input, file), 1), nil
}

func command(executable string, args ...string) error {
	process := exec.Command(executable, args...)
	process.Stdout = os.Stdout
	process.Stderr = os.Stderr
	return process.Run()
}

func replaceImports(code, formatted string) (string, error) {
	set := token.NewFileSet()
	file, err := parser.ParseFile(set, "", code, 0)
	if err != nil {
		return "", err
	}
	resolved, err := parser.ParseFile(token.NewFileSet(), "", formatted, 0)
	if err != nil {
		return "", err
	}
	for index := len(file.Decls) - 1; index >= 0; index-- {
		declaration, ok := file.Decls[index].(*ast.GenDecl)
		if !ok || declaration.Tok != token.IMPORT {
			continue
		}
		start := set.PositionFor(declaration.Pos(), false).Offset
		end := set.PositionFor(declaration.End(), false).Offset
		if end < len(code) && code[end] == ';' {
			end++
		}
		code = code[:start] + code[end:]
	}
	var imports strings.Builder
	for _, spec := range resolved.Imports {
		imports.WriteString("import ")
		if spec.Name != nil {
			imports.WriteString(spec.Name.Name + " ")
		}
		imports.WriteString(spec.Path.Value + "\n")
	}
	return strings.Replace(code, "package main\n", "package main\n"+imports.String(), 1), nil
}

func resolveImports(input request, code string) (string, error) {
	if input.Goimports == "" || firstToken(input.Code) == token.PACKAGE {
		return code, nil
	}
	var formatted bytes.Buffer
	process := exec.Command(input.Goimports, input.Path)
	process.Stdout = &formatted
	process.Stderr = os.Stderr
	if err := process.Run(); err != nil {
		return "", err
	}
	// Keep the snippet's original formatting and line directives for accurate diagnostics.
	return replaceImports(code, formatted.String())
}

func run(input request) error {
	code, err := prepare(input)
	if err != nil {
		return err
	}
	if err := os.WriteFile(input.Path, []byte(code), 0600); err != nil {
		return err
	}
	code, err = resolveImports(input, code)
	if err != nil {
		return err
	}
	if err := os.WriteFile(input.Path, []byte(code), 0600); err != nil {
		return err
	}
	args := append([]string{"run"}, input.Args...)
	return command(input.Executable, append(args, input.Path)...)
}

func main() {
	var input request
	if err := json.NewDecoder(os.Stdin).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if err := run(input); err != nil {
		fail(err)
	}
}

func fail(err error) {
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		os.Exit(exit.ExitCode())
	}
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
