# cproxsuite
ProxSuite C bindings
it follows API parts that exposed by python API.

> AI disclaimer: code of tools/nanobind_cgen.nim fully AI generated, without extensive refactorings etc, but generated api design and parsing ideas is my work and it spend 4 days to achieve this result

## Bindings generation

> [!NOTE]
> Generator requires nim

```sh
atlas install --feature=gen
nim generate
```

<br>

It has several differences from the original ProxQR API: each function has a proxsuite_c_context parameter,
which needed to implement error handling API:
```c
typedef struct proxsuite_c_context proxsuite_c_context;
typedef enum proxsuite_c_error_code {
  PROXSUITE_C_OK = 0,
  PROXSUITE_C_BAD_ALLOC = 1,
  PROXSUITE_C_INVALID_ARG = 2,
  PROXSUITE_C_EXCEPTION = 3,
  PROXSUITE_C_UNKNOWN_ERROR = 4
} proxsuite_c_error_code;

extern proxsuite_c_context *
proxsuite_c_context_create (void);

extern void
proxsuite_c_context_destroy (proxsuite_c_context *ctx);

extern proxsuite_c_error_code
proxsuite_c_context_get_error_code (proxsuite_c_context *ctx);

extern const char *
proxsuite_c_context_get_error_msg (proxsuite_c_context *ctx);
```

You should know that proxsuite_c_context_get_error_code is status of last call
if proxsuite_c_context_get_error_code(ctx) returns PROXSUITE_C_OK, proxsuite_c_context_get_error_msg(ctx) = NULL, otherwise error message.

It also allow to set custom error handler:
```c
typedef void (*proxsuite_c_error_handler)(
  proxsuite_c_context *ctx,
  proxsuite_c_error_code code,
  const char *msg,
  void *userdata);

extern void
proxsuite_c_context_set_error_handler (proxsuite_c_context *ctx,
                                       proxsuite_c_error_handler handler,
                                       void *userdata);

```

Important thing: sparse matrices like proxsuite_c_sparse_matrix_double_int always uses CSC format. In C++ with Eigen, this was clear from types, but for C code it should be pointed.

Currently, all generics materialized with double type, if you need float, write issue or make a pull request

