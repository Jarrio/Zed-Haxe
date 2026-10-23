; Text objects for Vim mode and "select larger/smaller syntax node":
; `af`/`if` select a function, `ac`/`ic` a type declaration, `gc` a comment.

(ClassMethod
    body: (EBlock
        "{"
        (_)* @function.inside
        "}")) @function.around

(ClassMethod) @function.around

(EFunction
    body: (EBlock
        "{"
        (_)* @function.inside
        "}")) @function.around

(EFunction) @function.around

(ClassType
    "{"
    (_)* @class.inside
    "}") @class.around

(AbstractType
    "{"
    (_)* @class.inside
    "}") @class.around

(EnumType
    "{"
    (_)* @class.inside
    "}") @class.around

(DefType) @class.around

(comment)+ @comment.around
