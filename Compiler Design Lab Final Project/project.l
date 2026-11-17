
%option noyywrap

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#define MAX 500

char sourceCode[1000];
char tok[MAX][64];
int nt = 0, pos = 0, tempNo = 0;

typedef struct Node {
    char value[64];
    char op;
    struct Node *left, *right;
} Node;

char *asmLines[1000];
int asmCount = 0;
char *tacLines[500];
int tacCount = 0;

char regName[4][3] = {"R0","R1","R2","R3"};
int used[4] = {0,0,0,0};

void addToken(const char *s) {
    if (nt < MAX) {
        strcpy(tok[nt++], s);
    }
}

%}

%%
[ \t\r\n]+                  ;
[A-Za-z_][A-Za-z0-9_]*      { addToken(yytext); }
[0-9]+(\.[0-9]+)?           { addToken(yytext); }
"=="|"!="|"<="|">="         { addToken(yytext); }
[+\-*/=();]                 { addToken(yytext); }
.                           { fprintf(stderr,
                              "Invalid character: %s\n", yytext); }
%%

Node *newLeaf(char *s) {
    Node *n = malloc(sizeof(Node));
    strcpy(n->value, s);
    n->op = 0;
    n->left = n->right = NULL;
    return n;
}

Node *newOp(char op, Node *l, Node *r) {
    Node *n = malloc(sizeof(Node));
    n->op = op;
    n->left = l;
    n->right = r;
    n->value[0] = '\0';
    return n;
}

int isLeaf(Node *n) {
    return n->op == 0;
}

Node *expression();

Node *factor() {
    if (pos >= nt) {
        fprintf(stderr, "Error: incomplete expression\n");
        exit(1);
    }

    if (strcmp(tok[pos], "(") == 0) {
        pos++;
        Node *n = expression();

        if (pos >= nt || strcmp(tok[pos], ")") != 0) {
            fprintf(stderr, "Error: missing ')'\n");
            exit(1);
        }

        pos++;
        return n;
    }

    if (strcmp(tok[pos], "-") == 0) {
        pos++;
        Node *n = newOp('-', newLeaf("0"), factor());
        return n;
    }

    if (!isalnum((unsigned char)tok[pos][0]) &&
        tok[pos][0] != '_') {
        fprintf(stderr, "Error: unexpected token %s\n", tok[pos]);
        exit(1);
    }

    return newLeaf(tok[pos++]);
}

Node *term() {
    Node *n = factor();

    while (pos < nt &&
          (strcmp(tok[pos], "*") == 0 ||
           strcmp(tok[pos], "/") == 0)) {
        char op = tok[pos++][0];
        n = newOp(op, n, factor());
    }

    return n;
}

Node *expression() {
    Node *n = term();

    while (pos < nt &&
          (strcmp(tok[pos], "+") == 0 ||
           strcmp(tok[pos], "-") == 0)) {
        char op = tok[pos++][0];
        n = newOp(op, n, term());
    }

    return n;
}

int depth(Node *n) {
    if (isLeaf(n)) return 0;

    int l = depth(n->left);
    int r = depth(n->right);
    return 1 + (l > r ? l : r);
}

int getReg() {
    for (int i = 0; i < 4; i++) {
        if (!used[i]) {
            used[i] = 1;
            return i;
        }
    }

    fprintf(stderr,
        "Error: expression needs more than 4 registers.\n");
    exit(1);
}

void freeReg(int r) {
    if (r >= 0 && r < 4)
        used[r] = 0;
}

void emit(const char *s) {
    asmLines[asmCount++] = strdup(s);
}

const char *instruction(char op) {
    switch (op) {
        case '+': return "ADD";
        case '-': return "SUB";
        case '*': return "MUL";
        case '/': return "DIV";
    }
    return "";
}

/* Returns register number for an expression.
   Leaf nodes are returned as operands, not registers. */
typedef struct Result {
    int reg;
    char text[64];
} Result;

Result generate(Node *n) {
    Result out;
    out.reg = -1;

    if (isLeaf(n)) {
        strcpy(out.text, n->value);
        return out;
    }

    Node *first = n->left;
    Node *second = n->right;
    int rightFirst = depth(second) > depth(first);

    Result a, b;

    if (rightFirst) {
        b = generate(second);
        a = generate(first);
    } else {
        a = generate(first);
        b = generate(second);
    }

    int target;

    if (a.reg >= 0) {
        target = a.reg;
    } else {
        target = getReg();

        char line[150];
        snprintf(line, sizeof(line), "MOV %s, %s",
                 regName[target], a.text);
        emit(line);
    }

    char line[150];
    snprintf(line, sizeof(line), "%s %s, %s",
             instruction(n->op), regName[target],
             b.reg >= 0 ? regName[b.reg] : b.text);
    emit(line);

    if (b.reg >= 0 && b.reg != target)
        freeReg(b.reg);

    out.reg = target;
    strcpy(out.text, regName[target]);
    return out;
}

void generateTAC(Node *n) {
    if (isLeaf(n)) return;

    generateTAC(n->left);
    generateTAC(n->right);

    char l[64], r[64], line[200];

    if (isLeaf(n->left))
        strcpy(l, n->left->value);
    else
        snprintf(l, sizeof(l), "t%d", tempNo);

    if (isLeaf(n->right))
        strcpy(r, n->right->value);
    else
        snprintf(r, sizeof(r), "t%d", tempNo);

    tempNo++;
    snprintf(line, sizeof(line), "t%d = %s %c %s",
             tempNo, l, n->op, r);
    tacLines[tacCount++] = strdup(line);
}

void printTAC(Node *n, char *destination) {
    tempNo = 0;
    tacCount = 0;
    generateTAC(n);

    printf("\nThree-Address Code:\n");

    for (int i = 0; i < tacCount; i++)
        printf("%s\n", tacLines[i]);

    if (isLeaf(n))
        printf("%s = %s\n", destination, n->value);
    else
        printf("%s = t%d\n", destination, tempNo);
}

int main() {
    printf("Enter assignment statement:\n");

    if (!fgets(sourceCode, sizeof(sourceCode), stdin))
        return 1;

    YY_BUFFER_STATE buffer = yy_scan_string(sourceCode);
    yylex();
    yy_delete_buffer(buffer);

    printf("\nTokens:\n");
    for (int i = 0; i < nt; i++)
        printf("%s ", tok[i]);
    printf("\n");

    if (nt < 3 || strcmp(tok[1], "=") != 0) {
        printf("Error: expected assignment, e.g. a = b + c;\n");
        return 1;
    }

    char destination[64];
    strcpy(destination, tok[0]);

    int end = nt;
    if (strcmp(tok[end - 1], ";") == 0)
        end--;

    /* Parse only the right-hand expression. */
    pos = 2;
    nt = end;

    Node *root = expression();

    if (pos != nt) {
        printf("Error: unexpected token %s\n", tok[pos]);
        return 1;
    }

    printTAC(root, destination);

    printf("\nPseudo-Assembly Code:\n");

    Result result = generate(root);

    char line[150];
    snprintf(line, sizeof(line), "MOV %s, %s",
             destination, result.text);
    emit(line);

    for (int i = 0; i < asmCount; i++)
        printf("%s\n", asmLines[i]);

    printf("\nRegister Descriptor:\n");
    for (int i = 0; i < 4; i++) {
        if (used[i])
            printf("%s: holds a computed value\n", regName[i]);
        else
            printf("%s: free\n", regName[i]);
    }

    return 0;
}
