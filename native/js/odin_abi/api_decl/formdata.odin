// FormData of module forms (api/forms.widl): the browser's entry lists, so that a FormData built from a <form> and the
// one a "formdata" event hands out are the lists the browser submits.
package api_decl

import "../abi"

FormData :: distinct abi.Handle

// new FormData(form, submitter): 0 for none. Invalid_Handle when the submitter is not a submit button of the form.
FormData_create :: #type proc(form: u64, submitter: u64) -> (FormData, abi.Api_Error)
FormData_append :: #type proc(data: FormData, name: string, value: string) -> abi.Api_Error
FormData_set :: #type proc(data: FormData, name: string, value: string) -> abi.Api_Error
// A file entry: the bytes in a buffer, its file name and MIME type.
FormData_appendBlob :: #type proc(data: FormData, name: string, blob: Buffer, filename: string, mime: string) -> abi.Api_Error
FormData_setBlob :: #type proc(data: FormData, name: string, blob: Buffer, filename: string, mime: string) -> abi.Api_Error
FormData_size :: #type proc(data: FormData) -> i32
// Entry `index`: its name, its value (a file's: the file name), whether it is a file, a file's type and bytes.
FormData_nameAt :: #type proc(data: FormData, index: i32) -> (string, abi.Api_Error)
FormData_valueAt :: #type proc(data: FormData, index: i32) -> (string, abi.Api_Error)
FormData_isFileAt :: #type proc(data: FormData, index: i32) -> (bool, abi.Api_Error)
FormData_fileTypeAt :: #type proc(data: FormData, index: i32) -> (string, abi.Api_Error)
FormData_fileAt :: #type proc(data: FormData, index: i32) -> (Buffer, abi.Api_Error)
// The entries as multipart/form-data with `boundary`, in a buffer.
FormData_encode :: #type proc(data: FormData, boundary: string) -> (Buffer, abi.Api_Error)
