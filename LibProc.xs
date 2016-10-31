/*   #define PERL_NO_GET_CONTEXT */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <demangle.h>
/*
#include <procfs.h>
#include <sys/procfs.h>
*/

#include "libproc.h"

/* Pre-XS C Function Declarations */
typedef struct {
  char                demangled_name[8192];
  unsigned long long  symvalue;
  unsigned long long  symsize;
} symtuple_t;

/* used to pass information between Pobject_iter()'s caller and callback */
typedef struct {
  struct ps_prochandle  *file_pshandle;
  /* The number of slots we've populated with symbols */
  long                   function_count;
  /* The number of slots we've allocated to handle */
  long                   max_symbol_count;
  symtuple_t            *tuples;
  /* TODO: Add something to show what the type of the file is, so we know how to
   * handle symbol resolution properly - static a.out or dynamic library */
} callback_data_t;



int         proc_object_iter(void *, void *, const char *);
int         function_iter(void *arg,
                          const GElf_Sym *sym,
                          const char *func_name);
callback_data_t *extract_symtuples(char *filename);
callback_data_t *extract_symtuples_from_PID(int pid);


/* C Functions */

/* Function used to grab ps_prochandle, invoke Pobject_Iter(), free up
 * resources, then return array of structs to XS routine */
callback_data_t *
extract_symtuples(char *filename) {
  int                   perr;
  struct ps_prochandle *exec_handle;
  callback_data_t      *cb_data;

  /* allocate memory for callback data structure to pass around */
  if ( (cb_data = malloc(sizeof(callback_data_t))) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "callback_data_t");
  }

  /* Allocate room for first 1000 symbol table function tuples */
  if ( (cb_data->tuples = malloc(sizeof(symtuple_t) * 1000)) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "first 1000 tuples");
  }

  cb_data->max_symbol_count = 1000;
  cb_data->function_count = 0;

  if ((exec_handle = Pgrab_file(filename, &perr)) == NULL) {
    croak("Unable to grab file: %s\n",Pgrab_error(perr));
  }

  /* Store the file_pshandle for later use in the callbacks */
  cb_data->file_pshandle = exec_handle;

  /* NOTE: Passing pshandle in as cb_data argument for use as first argument of
   *       Psymbol_iter later
   * TODO: Fix the case of proc_object_iter to void *, which is a hack */

  /* TODO: Since we're only doing one file at a time, we might be able to
   *       dispense with Pobject_iter() altogether and go straight to
   *       Psymbol_iter()
   */
  Pobject_iter(exec_handle, (void *)proc_object_iter, (void *)cb_data);

  Pfree(exec_handle);

  return(cb_data);
}

/* Function used to grab ps_prochandle for a PID and all of it's dependencies,
 * invoke Pobject_iter(), free up resources, then return array of structs to
 * XS routine */
callback_data_t *
extract_symtuples_from_PID(int pid) {
  int                   perr;
  struct ps_prochandle *exec_handle;
  callback_data_t      *cb_data;

  /* allocate memory for callback data structure to pass around */
  if ( (cb_data = malloc(sizeof(callback_data_t))) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "callback_data_t");
  }

  /* Allocate room for first 1000 symbol table function tuples */
  if ( (cb_data->tuples = malloc(sizeof(symtuple_t) * 1000)) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "first 1000 tuples");
  }

  cb_data->max_symbol_count = 1000;
  cb_data->function_count = 0;

  /* Use PGRAB_RDONLY to avoid perturbing the target PID */
  if ((exec_handle = Pgrab(pid, PGRAB_RDONLY, &perr)) == NULL) {
    croak("Unable to grab file: %s\n",Pgrab_error(perr));
  }

  /* NOTE: Passing pshandle in as cb_data argument for use as first argument of
   *       Psymbol_iter later
   * TODO: Fix the case of proc_object_iter to void *, which is a hack */

  /* TODO: Since we're only doing one file at a time, we might be able to
   *       dispense with Pobject_iter() altogether and go straight to
   *       Psymbol_iter()
   */
  Pobject_iter(exec_handle, (void *)proc_object_iter, (void *)cb_data);

  Pfree(exec_handle);

  return(cb_data);
}


/* Function called from within Pobject_iter() for each object
 * (usually just one)
 */
int
proc_object_iter(void *callback_arg, void *pmp, const char *object_name)
{
  callback_data_t      *cb_data;
  struct ps_prochandle *file_pshandle;
  int                   perr;

  cb_data       = (callback_data_t *)callback_arg;
  file_pshandle = cb_data->file_pshandle;

  /* - Only iterate over symbols that are functions
   * NOTE:
   *   - a.out's will generally have their symbol tables in PR_SYMTAB
   *   - dynamic libraries will generally have their symbol tables in PR_DYNSYM
   *   - So we try PR_SYMTAB first...
   */
  Psymbol_iter(file_pshandle,
               object_name,
               PR_SYMTAB,
               BIND_GLOBAL | BIND_LOCAL | TYPE_FUNC,
               (void *)function_iter,
               (void *)cb_data);
  /* ... and fall back to PR_DYNSYM if we found nothing */
  if (cb_data->function_count == 0) {
    Psymbol_iter(file_pshandle,
                 object_name,
                 PR_DYNSYM,
                 BIND_GLOBAL | BIND_LOCAL | TYPE_FUNC,
                 (void *)function_iter,
                 (void *)cb_data);
  }

  return 0;
}

/* Function called from within Psymbol_iter() for each symbol */
int
function_iter(void *callback_arg, const GElf_Sym *sym, const char *sym_name)
{
  callback_data_t *callback_data = (callback_data_t *)callback_arg;
  char            *proto_buffer;

  if ((proto_buffer = malloc(8192)) == NULL) {
    croak("Unable to allocate an 8K demangle prototype buffer");
  }

  /* If we've used up our allotted space, allocate 1000 more */
  if (callback_data->function_count >= callback_data->max_symbol_count) {
    if ( (callback_data->tuples =
            realloc(callback_data->tuples,
                    (sizeof(symtuple_t) * callback_data->max_symbol_count) +
                    (sizeof(symtuple_t) * 1000))) == NULL) {
      croak("Unable to allocate %ld + 1000 new symbol tuple slots",
            callback_data->max_symbol_count);
    }
    callback_data->max_symbol_count += 1000;
  }

  if (sym_name != NULL) {
    int demangle_result;
    size_t proto_buffer_size = (size_t)8192;
    retry:
    demangle_result = cplus_demangle(sym_name, proto_buffer,
                                     proto_buffer_size);
    switch (demangle_result) {
      case 0:
        /* Only record if the function symbol is "real" */
        if (sym->st_size > 0) {
          strcpy(callback_data->tuples[callback_data->function_count].demangled_name,
                 proto_buffer);
          callback_data->tuples[callback_data->function_count].symvalue = sym->st_value;
          callback_data->tuples[callback_data->function_count].symsize  = sym->st_size;
          callback_data->function_count++;
          /* printf("%-32s %llu %llu\n", proto_buffer, sym->st_value, sym->st_size); */
        }
        break;
      case DEMANGLE_ENAME:
         /* Only record if the function symbol is "real" */
        if (sym->st_size > 0) {
          strcpy(callback_data->tuples[callback_data->function_count].demangled_name,
                 sym_name);
          callback_data->tuples[callback_data->function_count].symvalue = sym->st_value;
          callback_data->tuples[callback_data->function_count].symsize  = sym->st_size;
          callback_data->function_count++;
          /* printf("%-32s %llu %llu\n", sym_name, sym->st_value, sym->st_size); */
        }
        /* printf("SKIPPING INVALID MANGLED NAME %s\n",sym_name); */
        break;
      case DEMANGLE_ESPACE:
        proto_buffer_size += 8192;
        if ((proto_buffer = realloc(proto_buffer, proto_buffer_size)) == NULL) {
          croak("Unable to expand demangle prototype buffer to %lld\n",proto_buffer_size);
        }
        goto retry;
      default:
        croak("cplus_demangle() failed with unknown error %d\n",
              demangle_result);
        break;
    }
  } else {
    croak("NULL FUNCNAME");
  }
  free(proto_buffer);
  return(0);
}



/* And now the XS code, for C functions we want to access directly from Perl */

/* Note the name of LibProc instead of libproc, to avoid collision with
 * libproc.so */


MODULE = DTrace::UStackResolve  PACKAGE = DTrace::UStackResolve

# XS code

PROTOTYPES: ENABLED

AV *
extract_symtab(char *filename)
  PREINIT:
    char            *my_option;
    AV              *rval;
    HV              *hash;
    SV              *temp_href;
    callback_data_t *raw_symbol_struct;
    symtuple_t      *symtuple_array;
    long             i;
  CODE:
    if (items == 1) {
      if (! SvPOK( ST(0) )) {
        croak("setopt: Option must be a string");
      }
      my_option = (char *)SvPV_nolen(ST(0));
    } else {
      croak("extract_symtab: argument must be a filename");
    }

    raw_symbol_struct = extract_symtuples(my_option);
    /* warn("We pulled %ld symbols\n",raw_symbol_struct->function_count); */

    symtuple_array = raw_symbol_struct->tuples;

    warn("Extracted symbols from libproc\n");
    rval = newAV();

    for (i = 0; i < raw_symbol_struct->function_count; i++) {
      hash = newHV();
      hv_store(hash, "function", 8,
               newSVpv(symtuple_array[i].demangled_name, 0), 0);
      hv_store(hash, "start",    5,
              newSViv(symtuple_array[i].symvalue), 0);
      hv_store(hash, "size",     4,
              newSViv(symtuple_array[i].symsize), 0);
      temp_href = newRV_noinc( (SV *)hash );
      av_push(rval, temp_href);
    }
    free(raw_symbol_struct->tuples);
    free(raw_symbol_struct);

    RETVAL = rval;
  OUTPUT:
    RETVAL

AV *
extract_symtab_from_pid(int pid)
  PREINIT:
    int              my_option;
    AV              *rval;
    HV              *hash;
    SV              *temp_href;
    callback_data_t *raw_symbol_struct;
    symtuple_t      *symtuple_array;
    long             i;
  CODE:
    if (items == 1) {
      if (! SvIOK( ST(0) )) {
        croak("setopt: Option must be an integer");
      }
      my_option = SvIV(ST(0));
    } else {
      croak("extract_symtab_from_pid: argument must be a single PID");
    }

    raw_symbol_struct = extract_symtuples_from_PID(my_option);
    warn("We pulled %ld symbols\n",raw_symbol_struct->function_count);

    symtuple_array = raw_symbol_struct->tuples;

    rval = newAV();

    for (i = 0; i < raw_symbol_struct->function_count; i++) {
      hash = newHV();
      hv_store(hash, "function", 8,
               newSVpv(symtuple_array[i].demangled_name, 0), 0);
      hv_store(hash, "start",    5,
              newSViv(symtuple_array[i].symvalue), 0);
      hv_store(hash, "size",     4,
              newSViv(symtuple_array[i].symsize), 0);
      temp_href = newRV_noinc( (SV *)hash );
      av_push(rval, temp_href);
    }
    free(raw_symbol_struct->tuples);
    free(raw_symbol_struct);

    RETVAL = rval;
  OUTPUT:
    RETVAL

