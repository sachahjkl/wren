package page

// TEMPORARY stubs so `odin check` can type the webcodecs host code before bindgen regenerates api_generated.odin.
// DELETE before handing off: the real Api_* are generated from api/webcodecs*.widl.
Api_VideoFrame :: struct { handle: u64, data: ^Video_Frame_Obj }
Api_ImageDecoder :: struct { handle: u64, data: ^Image_Decoder_Obj }
Api_ImageTrack :: struct { handle: u64, data: ^Image_Track_Obj }
Api_ImageTrackList :: struct { handle: u64, data: ^Image_Track_Obj }
