package main

import "core:fmt"

// See https://developer.mozilla.org/en-US/docs/Web/HTTP/Basics_of_HTTP/MIME_types/Common_types
Mime_Type :: enum {
	Unknown,
	Any,
	Any_Application,
	Any_Audio,
	Any_Font,
	Any_Image,
	Any_Text,
	Any_Video,
	Application_7zip, // application/x-7z-compressed
	Application_AbiWord, // application/x-abiword
	Application_Apple_Package, // application/vnd.apple.installer+xml
	Application_Archive, // application/x-freearc
	Application_Atom, // application/atom+xml
	Application_Binary, // application/octet-stream
	Application_BZip, // application/x-bzip
	Application_BZip2, // application/x-bzip2
	Application_C_Shell, // application/x-csh
	Application_CD_Audio, // application/x-cdf
	Application_EPUB, // application/epub+zip
	Application_Excel, // application/vnd.ms-excel
	Application_ExcelX, // application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
	Application_JAR, // application/java-archive
	Application_JSON, // application/json
	Application_JSON_LD, // application/ld+json
	Application_Kindle, // application/vnd.amazon.ebook
	Application_OGG, // application/ogg
	Application_OpenDoc_Presentation, // application/vnd.oasis.opendocument.presentation
	Application_OpenDoc_Spreadsheet, // application/vnd.oasis.opendocument.spreadsheet
	Application_OpenDoc_Doc, // application/vnd.oasis.opendocument.text
	Application_PDF, // application/pdf
	Application_PHP, // application/x-httpd-php
	Application_PowerPoint, // application/vnd.ms-powerpoint
	Application_PowerPointX, // application/vnd.openxmlformats-officedocument.presentationml.presentation
	Application_RAR, // application/vnd.rar
	Application_RTF, // application/rtf
	Application_SH, // application/x-sh
	Application_TAR, // application/x-tar
	Application_Word_Doc, // application/msword
	Application_Word_DocX, // application/vnd.openxmlformats-officedocument.wordprocessingml.document
	Application_OpenType, // application/otf
	Application_OpenType_Embedded, // application/vnd.ms-fontobject
	Application_Visio, // application/vnd.visio
	Application_XHTML, // application/xhtml+xml
	Application_XML, // application/xml | text/xml
	Application_XUL, // application/vnd.mozilla.xul+xml
	Application_ZIP, // application/zip
	Audio_3GPP, // audio/3gpp
	Audio_3GPP2, // audio/3gpp2
	Audio_AAC, // audio/aac
	Audio_MIDI, // audio/midi | audio/x-midi
	Audio_MP3, // audio/mpeg
	Audio_OGG, // audio/ogg
	Audio_Opus, // audio/opus
	Audio_SVG, // audio/svg+xml
	Audio_WAV, // audio/wav
	Audio_WEBM, // audio/webm
	Font_TTF, // font/ttf
	Font_WOFF, // font/woff
	Font_WOFF2, // font/woff2
	Image_APNG, // image/apng
	Image_AVIF, // image/avif
	Image_BMP, // image/bmp
	Image_GIF, // image/gif
	Image_Icon, // image/vnd.microsoft.icon
	Image_JPEG, // image/jpeg
	Image_TIFF, // image/tiff
	Image_PNG, // image/png
	Image_WEBP, // image/webp
	Text_CSS, // text/css
	Text_CSV, // text/csv
	Text_HTML, // text/html
	Text_JavaScript, // text/javascript
	Text_iCalendar, // text/calendar
	Text_Plain, // text/plain
	Video_3GPP, // video/3gpp
	Video_3GPP2, // video/3gpp2
	Video_AVI, // video/x-msvideo
	Video_MP4, // video/mp4
	Video_MPEG, // video/mpeg
	Video_MPEG_Stream, // video/mp2t
	Video_OGG, // video/ogg
	Video_WEBM, // video/webm
}

// TODO: Q-Factor Weighting (https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Accept)
content_to_mime :: proc(content_type: string) -> Mime_Type {
	switch content_type {
	case "*/*":
		return .Any

	case "application/*":
		return .Any_Application
	case "audio/*":
		return .Any_Audio
	case "font/*":
		return .Any_Font
	case "image/*":
		return .Any_Image
	case "text/*":
		return .Any_Text
	case "video/*":
		return .Any_Video

	case "application/x-7z-compressed":
		return .Application_7zip
	case "application/x-abiword":
		return .Application_AbiWord
	case "application/vnd.apple.installer+xml":
		return .Application_Apple_Package
	case "application/x-freearc":
		return .Application_Archive
	case "application/atom+xml":
		return .Application_Atom
	case "application/octet-stream":
		return .Application_Binary
	case "application/x-bzip":
		return .Application_BZip
	case "application/x-bzip2":
		return .Application_BZip2
	case "application/x-csh":
		return .Application_C_Shell
	case "application/x-cdf":
		return .Application_CD_Audio
	case "application/epub+zip":
		return .Application_EPUB
	case "application/vnd.ms-excel":
		return .Application_Excel
	case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet":
		return .Application_ExcelX
	case "application/java-archive":
		return .Application_JAR
	case "application/json":
		return .Application_JSON
	case "application/ld+json":
		return .Application_JSON_LD
	case "application/vnd.amazon.ebook":
		return .Application_Kindle
	case "application/ogg":
		return .Application_OGG
	case "application/vnd.oasis.opendocument.presentation":
		return .Application_OpenDoc_Presentation
	case "application/vnd.oasis.opendocument.spreadsheet":
		return .Application_OpenDoc_Spreadsheet
	case "application/vnd.oasis.opendocument.text":
		return .Application_OpenDoc_Doc
	case "application/pdf":
		return .Application_PDF
	case "application/x-httpd-php":
		return .Application_PHP
	case "application/vnd.ms-powerpoint":
		return .Application_PowerPoint
	case "application/vnd.openxmlformats-officedocument.presentationml.presentation":
		return .Application_PowerPointX
	case "application/vnd.rar":
		return .Application_RAR
	case "application/rtf":
		return .Application_RTF
	case "application/x-sh":
		return .Application_SH
	case "application/x-tar":
		return .Application_TAR
	case "application/msword":
		return .Application_Word_Doc
	case "application/vnd.openxmlformats-officedocument.wordprocessingml.document":
		return .Application_Word_DocX
	case "application/otf":
		return .Application_OpenType
	case "application/vnd.ms-fontobject":
		return .Application_OpenType_Embedded
	case "application/vnd.visio":
		return .Application_Visio
	case "application/xhtml+xml":
		return .Application_XHTML
	case "application/xml | text/xml":
		return .Application_XML
	case "application/vnd.mozilla.xul+xml":
		return .Application_XUL
	case "application/zip":
		return .Application_ZIP

	case "audio/3gpp":
		return .Audio_3GPP
	case "audio/3gpp2":
		return .Audio_3GPP2
	case "audio/aac":
		return .Audio_AAC
	case "audio/midi | audio/x-midi":
		return .Audio_MIDI
	case "audio/mpeg":
		return .Audio_MP3
	case "audio/ogg":
		return .Audio_OGG
	case "audio/opus":
		return .Audio_Opus
	case "audio/svg+xml":
		return .Audio_SVG
	case "audio/wav":
		return .Audio_WAV
	case "audio/webm":
		return .Audio_WEBM

	case "font/ttf":
		return .Font_TTF
	case "font/woff":
		return .Font_WOFF
	case "font/woff2":
		return .Font_WOFF2

	case "image/apng":
		return .Image_APNG
	case "image/avif":
		return .Image_AVIF
	case "image/bmp":
		return .Image_BMP
	case "image/gif":
		return .Image_GIF
	case "image/vnd.microsoft.icon":
		return .Image_Icon
	case "image/jpeg":
		return .Image_JPEG
	case "image/tiff":
		return .Image_TIFF
	case "image/png":
		return .Image_PNG
	case "image/webp":
		return .Image_WEBP

	case "text/css":
		return .Text_CSS
	case "text/csv":
		return .Text_CSV
	case "text/html":
		return .Text_HTML
	case "text/javascript":
		return .Text_JavaScript
	case "text/calendar":
		return .Text_iCalendar
	case "text/plain":
		return .Text_Plain

	case "video/3gpp":
		return .Video_3GPP
	case "video/3gpp2":
		return .Video_3GPP2
	case "video/x-msvideo":
		return .Video_AVI
	case "video/mp4":
		return .Video_MP4
	case "video/mpeg":
		return .Video_MPEG
	case "video/mp2t":
		return .Video_MPEG_Stream
	case "video/ogg":
		return .Video_OGG
	case "video/webm":
		return .Video_WEBM
	}

	return .Unknown
}

ext_to_content :: proc(ext: string) -> string {
	switch ext {
	case "html", "htm":
		return "text/html"
	case "txt":
		return "text/plain"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "png":
		return "image/png"
	case:
		return "application/octet-stream"
	}
}
