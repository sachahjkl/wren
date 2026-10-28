// Converted from the matching api/*.widl by bindgen -convert-widl. The Odin form is the source of truth once the .widl is removed; see src/tools/bindgen/idl/odin_in.odin.
//@wb module name=web order=67 exposed=(Window,Worker)
/// What every other module shares: the error codes (Web IDL exceptions and DOMException names), the exception record
/// of the calling module, and the entry point of a page module.
package api_web

/// The status of a function that raises: 0, or what went wrong. Promise rejections use the same codes.
Error :: enum i32 {
	None = 0,
	/// A handle that is not live, or not of the kind the function takes.
	Invalid_Handle = -1,
	/// HierarchyRequestError: the node cannot go there.
	Hierarchy = -2,
	/// NotFoundError, or a null result ("no such attribute", "no such entry").
	Not_Found = -3,
	/// An argument out of its range (an enum, an index, a size).
	Invalid_Argument = -4,
	/// A node that is still in the tree cannot be released.
	Attached = -5,
	/// TypeError.
	Type = -10,
	/// RangeError.
	Range = -11,
	/// SecurityError.
	Security = -12,
	/// QuotaExceededError.
	Quota = -13,
	/// NotSupportedError.
	Not_Supported = -14,
	/// SyntaxError.
	Syntax = -15,
	/// AbortError.
	Abort = -16,
	/// TimeoutError.
	Timeout = -17,
	/// InvalidStateError.
	Invalid_State = -18,
	/// DataCloneError.
	Data_Clone = -19,
	/// NetworkError (fetch failures; the message says why).
	Network = -20,
	/// EncodingError.
	Encoding = -21,
	/// IndexSizeError.
	Index_Size = -22,
	/// NotAllowedError.
	Not_Allowed = -23,
	/// InvalidAccessError.
	Invalid_Access = -24,
	/// InvalidCharacterError (a name that is not a valid XML name, a token with spaces...).
	Invalid_Character = -40,
	/// NamespaceError.
	Namespace = -41,
	/// InUseAttributeError.
	In_Use_Attribute = -42,
	/// WrongDocumentError.
	Wrong_Document = -43,
	/// InvalidNodeTypeError.
	Invalid_Node_Type = -44,
	/// InvalidModificationError.
	Invalid_Modification = -45,
	/// NoModificationAllowedError.
	No_Modification_Allowed = -46,
}

/// The code of the last error a function raised to this module instance (0 when none did yet).
//@wb fn
Exception_code :: proc() -> Error

/// The message of that error ("" when it has none): what a DOMException's message would say.
//@wb fn
Exception_message :: proc() -> string

/// Called once the module is instantiated in a page (after the document is parsed), if the module exports it.
//@wb export
wb_main :: proc()

