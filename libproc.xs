/*   #define PERL_NO_GET_CONTEXT */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <demangle.h>

#include <procfs.h>
#include <sys/procfs.h>

#include "libproc.h"

/* Pre-XS C Function Declarations */
/* used to pass information between Pobject_iter()'s caller and callback */
typedef struct {
  struct ps_prochandle  *file_pshandle;
  long                   function_count;
  /* TODO: Add something to show what the type of the file is, so we know how to
   * handle symbol resolution properly - static a.out or dynamic library */
} data_t;

typedef struct {
} symtuple_t;

int         proc_object_iter(void *, const prmap_t *, const char *);
int         function_iter(void *arg,
                          const GElf_Sym *sym,
                          const char *func_name);
symtuple_t *extract_symtuples(char *filename);


/* C Functions */

/* Function used to grab ps_prochandle, invoke Pobject_Iter(), free up
 * resources, then return array of structs to XS routine */
symtuple_t *
extract_symtuples(char *filename) {
  int                   perr;
  struct ps_prochandle *exec_handle;

  /* Use PGRAB_RDONLY to avoid perturbing the target PID */
  if ((exec_handle = Pgrab_file(filename, &perr)) == NULL) {
    printf("Unable to grab file: %s\n",Pgrab_error(perr));
    exit(2);
  }

  /* NOTE: Passing pshandle in as cd argument for use as first argument of
   * Psymbol_iter later */
  Pobject_iter(exec_handle, proc_object_iter, (void *)NULL);

  Pfree(exec_handle);
}

/* Function called from within Pobject_iter() for each object
 * (usually just one) */
int
proc_object_iter(void *callback_arg, const prmap_t *pmp, const char *object_name)
{
  data_t                procfile_data;
  struct ps_prochandle *file_pshandle;
  int                   perr;


  /* printf("proc_object_iter: %-120s\n", object_name); */
  /* For each object name, grab the file, then iterate over the objects,
   * extracting their symbol tables */
  if ((file_pshandle = Pgrab_file(object_name, &perr)) == NULL) {
    printf("Unable to grab file: %s\n",Pgrab_error(perr));
  }
  /* NOTE: Passing file_pshandle in for use as callback argument for
   * Psymbol_iter later */
  procfile_data.file_pshandle = file_pshandle;
  procfile_data.function_count = 0;

  Psymbol_iter(file_pshandle,
               object_name,
               PR_SYMTAB,
               BIND_GLOBAL | TYPE_FUNC,
               function_iter,
               (void *)&procfile_data);

  /* printf("FUNCTION COUNT: %ld\n", procfile_data.function_count); */

  return 0;
}

/* Function called from within Psymbol_iter() for each symbol */
int
function_iter(void *callback_arg, const GElf_Sym *sym, const char *sym_name)
{
  data_t procfile_data = (*((data_t *)callback_arg));
  char   proto_buffer[8192];

  if (sym_name != NULL) {
    int demangle_result;
    cplus_demangle(sym_name, proto_buffer, (size_t)8192);
    switch (demangle_result) {
      case 0:
        printf("%-32s %llu %llu\n", proto_buffer, sym->st_value, sym->st_size);
        break;
      case DEMANGLE_ENAME:
        printf("INVALID MANGLED NAME\n");
        exit(4);
        break;
      case DEMANGLE_ESPACE:
        printf("Demangle BUFFER TOO SMALL\n");
        exit(5);
        break;
      default:
        printf("cplus_demangle() failed with unknown error %d\n",demangle_result);
        exit(6);
        break;
    }
    (((data_t *)callback_arg)->function_count)++;
  } else {
    printf("\tNULL FUNCNAME\n");
  }
  return 0;
}



/* And now the XS code, for C functions we want to access directly from Perl */

MODULE = DTrace::UStackResolve::libproc  PACKAGE = DTrace::UStackResolve::libproc

# XS code

PROTOTYPES: ENABLED


