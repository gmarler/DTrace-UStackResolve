/*   #define PERL_NO_GET_CONTEXT */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "ppport.h"

#include <stdlib.h>
#include <demangle.h>
/*
#include <procfs.h>
#include <sys/procfs.h>
*/

#include "libproc.h"

/* Pre-XS C Function Declarations */
typedef struct {
  char               *demangled_name;
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



int         symstart_comparator(const void *p, const void *q);
int         proc_object_iter(void *, void *, const char *);
int         function_iter(void *arg,
                          const GElf_Sym *sym,
                          const char *func_name);
callback_data_t *extract_symtuples(char *filename);


/* C Functions */

/* Function used by qsort() in sorting our symbol table before returning it to
 * Perl */
int symstart_comparator(const void *p, const void *q)
{
  int l = ((symtuple_t *)p)->symvalue;
  int r = ((symtuple_t *)q)->symvalue;
  return (l - r);
}

/* Function used to grab ps_prochandle, invoke Pobject_Iter(), free up
 * resources, then return array of structs to XS routine */
callback_data_t *
extract_symtuples(char *filename) {
  int                   perr;
  struct ps_prochandle *exec_handle;
  callback_data_t      *cb_data;

  /* allocate memory for callback data structure to pass around */
  if ( (cb_data = calloc(1, sizeof(callback_data_t))) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "callback_data_t");
  }

  /* Allocate room for first 10 symbol table function tuples */
  if ( (cb_data->tuples = calloc(10, sizeof(symtuple_t))) == NULL ) {
    croak("%s unable to allocate memory for %s\n",
          "DTrace::UStackResolve::LibProc::extract_symtuples",
          "first 10 tuples");
  }

  cb_data->max_symbol_count = 10;
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

  /* return immediately so no memory is allocated if the function has no
   * size - that means it isn't "real" */
  if (sym->st_size == 0) {
    return(0);
  }

  if ((proto_buffer = calloc(1, 512)) == NULL) {
    croak("Unable to allocate an 512 byte demangle prototype buffer");
  }

  /* If we've used up our allotted space, allocate 1000 more */
  if (callback_data->function_count >= callback_data->max_symbol_count) {
    if ( (callback_data->tuples =
            realloc(callback_data->tuples,
                    (sizeof(symtuple_t) * callback_data->max_symbol_count) +
                    (sizeof(symtuple_t) * 10))) == NULL) {
      croak("Unable to allocate %ld + 10 new symbol tuple slots",
            callback_data->max_symbol_count);
    }
    callback_data->max_symbol_count += 10;
  }

  if (sym_name != NULL) {
    int demangle_result;
    size_t proto_buffer_size = (size_t)512;
    retry:
    demangle_result = cplus_demangle(sym_name, proto_buffer,
                                     proto_buffer_size);
    switch (demangle_result) {
      case 0:
        callback_data->tuples[callback_data->function_count].demangled_name =
          strdup(proto_buffer);
        callback_data->tuples[callback_data->function_count].symvalue = sym->st_value;
        callback_data->tuples[callback_data->function_count].symsize  = sym->st_size;
        callback_data->function_count++;
        /* printf("%-32s %llu %llu\n", proto_buffer, sym->st_value, sym->st_size); */
        break;
      case DEMANGLE_ENAME:
        /* Didn't need demangling anyway - use as is */
        callback_data->tuples[callback_data->function_count].demangled_name =
          strdup(sym_name);
        callback_data->tuples[callback_data->function_count].symvalue = sym->st_value;
        callback_data->tuples[callback_data->function_count].symsize  = sym->st_size;
        callback_data->function_count++;
        /* printf("%-32s %llu %llu\n", sym_name, sym->st_value, sym->st_size); */
        break;
      case DEMANGLE_ESPACE:
        proto_buffer_size *= 2;
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
    AV              *symtab_entry_aref;
    HV              *hash;
    SV              *temp_href;
    SV              *temp_aref;
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

    /* pre-sort the symtuple array by symbol start address before returning -
     * this consumes far too much memory if we do it in Perl, as in-place
     * sorting doesn't actually work for arefs of arefs */
    qsort(symtuple_array, raw_symbol_struct->function_count,
          sizeof(symtuple_t), symstart_comparator );

    /* warn("Extracted symbols from libproc\n"); */
    rval = newAV();

    for (i = 0; i < raw_symbol_struct->function_count; i++) {
      symtab_entry_aref = newAV();

      /* Index 0 == Function Name */
      av_push(symtab_entry_aref,
              newSVpv(symtuple_array[i].demangled_name, 0));

      /* Free the allocated space for each function name */
      if (symtuple_array[i].demangled_name) {
        free(symtuple_array[i].demangled_name);
      }

      /* Index 1 == Function Start Address */
      av_push(symtab_entry_aref, newSViv(symtuple_array[i].symvalue));

      /* Index 2 == Function Size */
      av_push(symtab_entry_aref, newSViv(symtuple_array[i].symsize));

      temp_aref = newRV_noinc( (SV *)symtab_entry_aref );
      av_push(rval, temp_aref);
    }
    free(raw_symbol_struct->tuples);
    free(raw_symbol_struct);

    RETVAL = rval;
  OUTPUT:
    RETVAL


