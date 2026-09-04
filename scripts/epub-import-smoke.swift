import Foundation
import BooksCore
import BooksPlatform

let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("stillleaf-import-smoke-" + UUID().uuidString)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporary) }
let fixtureScript = #"""
import zipfile,sys,os,stat
root=sys.argv[1]
container='<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
opf='<package xmlns="http://www.idpf.org/2007/opf" version="3.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><metadata><dc:title>Fixture title</dc:title><dc:creator>Fixture author</dc:creator></metadata><manifest><item id="ch" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="cover" href="cover.png" media-type="image/png" properties="cover-image"/></manifest><spine><itemref idref="ch"/></spine></package>'
base=[('mimetype','application/epub+zip'),('META-INF/container.xml',container),('EPUB/book.opf',opf),('EPUB/chapter.xhtml','<html><body>Hello</body></html>'),('EPUB/cover.png','cover')]
def make(name,entries):
 with zipfile.ZipFile(os.path.join(root,name+'.epub'),'w',compression=zipfile.ZIP_DEFLATED) as z:
  for p,d in entries:z.writestr(p,d)
make('safe',base)
# Independent SHA1 known-answer vector for identifier 'abc', with XML whitespace removed.
key=bytes.fromhex('a9993e364706816aba3e25717850c26c9cd0d89d')
plain=bytes(i%251 for i in range(1500))
encoded=bytes(b^key[i%20] if i<1040 else b for i,b in enumerate(plain))
fontopf=opf.replace('version="3.0"','version="3.0" unique-identifier="uid"').replace('</metadata>','<dc:identifier id="uid"> a&#x9;b&#xD;&#xA;c </dc:identifier></metadata>').replace('</manifest>','<item id="font" href="font.otf" media-type="font/otf"/></manifest>')
fontbase=[(p,fontopf if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/font.otf',encoded)]
encryption='<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:e="http://www.w3.org/2001/04/xmlenc#"><e:EncryptedData><e:EncryptionMethod Algorithm="http://www.idpf.org/2008/embedding"/><e:CipherData><e:CipherReference URI="EPUB/font.otf"/></e:CipherData></e:EncryptedData></encryption>'
make('font',fontbase+[('META-INF/encryption.xml',encryption)])
make('fontshort',[(p,d[:17] if p=='EPUB/font.otf' else d) for p,d in fontbase]+[('META-INF/encryption.xml',encryption)])
for name,xml in [('method',encryption.replace('http://www.idpf.org/2008/embedding','http://ns.adobe.com/pdf/enc#RC')),('remote',encryption.replace('EPUB/font.otf','https://example.com/font.otf')),('traversal',encryption.replace('EPUB/font.otf','../font.otf')),('missing',encryption.replace('EPUB/font.otf','EPUB/missing.otf')),('nonfont',encryption.replace('EPUB/font.otf','EPUB/chapter.xhtml')),('namespace',encryption.replace('http://www.w3.org/2001/04/xmlenc#','urn:bogus')),('duplicate',encryption.replace('</encryption>',encryption[encryption.index('<e:EncryptedData>'):encryption.index('</encryption>')]+'</encryption>')),('transform',encryption.replace('/></e:CipherData>','><e:Transforms/></e:CipherReference></e:CipherData>')),('base',encryption.replace('<e:CipherData>','<e:CipherData xml:base="../">'))]:
 make('fontbad-'+name,fontbase+[('META-INF/encryption.xml',xml)])
for name,package in [('noid',fontopf.replace(' unique-identifier="uid"','')),('duplicateid',fontopf.replace('</metadata>','<dc:identifier id="uid">abc</dc:identifier></metadata>')),('wrongid',fontopf.replace('id="uid"','id="other"')),('blankid',fontopf.replace(' a&#x9;b&#xD;&#xA;c ',' &#x9; ')),('wrongnamespace',fontopf.replace('http://purl.org/dc/elements/1.1/','urn:wrong'))]:
 make('fontbad-'+name,[(p,package if p=='EPUB/book.opf' else d) for p,d in fontbase]+[('META-INF/encryption.xml',encryption)])

nav='<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><body><nav epub:type="toc"><ol><li><a href="chapter.xhtml#start">Part &amp; One</a><ol><li><a href="chapter.xhtml#fn1">A <span>nested</span> note</a></li></ol></li></ol></nav><nav epub:type="landmarks"><ol><li><a href="chapter.xhtml#start">Begin reading</a></li></ol></nav><nav epub:type="page-list"><ol><li><a href="chapter.xhtml#page7">7</a></li></ol></nav></body></html>'
navbase=[(p,d.replace('</manifest>','<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest>') if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/nav.xhtml',nav)]
make('navigation',navbase)
make('navprefix',[(p,d.replace('xmlns:epub=', 'xmlns:ops=').replace('epub:type=', 'ops:type=') if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('navremote',[(p,d.replace('chapter.xhtml#start','https://example.com/chapter.xhtml') if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('navtraversal',[(p,d.replace('chapter.xhtml#start','../../outside.xhtml') if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('navunknown',[(p,d.replace('chapter.xhtml#start','missing.xhtml') if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
ncx='<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap><navPoint><navLabel><text>Chapter &amp; title</text></navLabel><content src="chapter.xhtml#start"/><navPoint><navLabel><text>Footnote</text></navLabel><content src="chapter.xhtml#fn1"/></navPoint></navPoint></navMap><pageList><pageTarget><navLabel><text>7</text></navLabel><content src="chapter.xhtml#page7"/></pageTarget></pageList></ncx>'
make('ncx',[(p,d.replace('version="3.0"','version="2.0"').replace('</manifest>','<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>').replace('<spine>','<spine toc="ncx">').replace('</package>','<guide><reference type="text" title="Start &amp; read" href="chapter.xhtml#start"/></guide></package>') if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/toc.ncx',ncx)])

# Adobe's legacy font obfuscation: XOR the first 1024 bytes with the 16 bytes of a urn:uuid,
# here a secondary identifier beside an ISBN, with a legacy font media type.
adobe_uuid='0f2e7c3a-9b1d-4e5f-8a6b-1c2d3e4f5a6b'
adobe_key=bytes.fromhex(adobe_uuid.replace('-',''))
adobe_plain=b'OTTO'+bytes(i%249 for i in range(2000))
adobe_encoded=bytes(b^adobe_key[i%16] if i<1024 else b for i,b in enumerate(adobe_plain))
adobe_opf=opf.replace('version="3.0"','version="3.0" unique-identifier="isbn"').replace('</metadata>','<dc:identifier id="isbn">9780000000000</dc:identifier><dc:identifier>urn:uuid:'+adobe_uuid+'</dc:identifier></metadata>').replace('</manifest>','<item id="font" href="font.otf" media-type="application/x-font-otf"/></manifest>')
adobe_encryption=encryption.replace('http://www.idpf.org/2008/embedding','http://ns.adobe.com/pdf/enc#RC')
make('adobefont',[(p,adobe_opf if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/font.otf',adobe_encoded),('META-INF/encryption.xml',adobe_encryption)])
make('adobenoise',[(p,adobe_opf.replace(adobe_uuid,'11111111-2222-3333-4444-555555555555') if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/font.otf',adobe_encoded),('META-INF/encryption.xml',adobe_encryption)])
# A plain DOCTYPE is ordinary in EPUB 2 NCX and EPUB 3 XHTML; an internal subset is not allowed.
ncx_doctype='<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">'
make('ncxdoctype',[(p,d.replace('version="3.0"','version="2.0"').replace('</manifest>','<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>').replace('<spine>','<spine toc="ncx">') if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/toc.ncx',ncx_doctype+ncx)])
make('navdoctype',[(p,'<!DOCTYPE html>'+d if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('navdtdsubset',[(p,'<!DOCTYPE html [<!ELEMENT x ANY>]>'+d if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('navtwodoctypes',[(p,'<!DOCTYPE html><!DOCTYPE html>'+d if p=='EPUB/nav.xhtml' else d) for p,d in navbase])
make('rtl',[(p,d.replace('</metadata>','<dc:language>ar</dc:language><dc:language>en-US</dc:language></metadata>').replace('<spine>','<spine page-progression-direction="rtl">') if p=='EPUB/book.opf' else d) for p,d in base])
make('badlanguage',[(p,d.replace('</metadata>','<dc:language>'+('x'*129)+'</dc:language></metadata>') if p=='EPUB/book.opf' else d) for p,d in base])
make('baddirection',[(p,d.replace('<spine>','<spine page-progression-direction="vertical">') if p=='EPUB/book.opf' else d) for p,d in base])
make('fixedlayout',[(p,d.replace('</metadata>','<meta property="rendition:layout">pre-paginated</meta></metadata>') if p=='EPUB/book.opf' else d) for p,d in base])
make('nonlinear',[(p,d.replace('</manifest>','<item id="appendix" href="appendix.xhtml" media-type="application/xhtml+xml"/></manifest>').replace('</spine>','<itemref idref="appendix" linear="no"/></spine>') if p=='EPUB/book.opf' else d) for p,d in base]+[('EPUB/appendix.xhtml','<html><body>Appendix</body></html>')])
make('traversal',base+[('../outside','bad')])
make('absolute',base+[('/tmp/outside','bad')])
make('backslash',base+[('EPUB\\evil','bad')])
make('duplicate',base+[('EPUB/chapter.xhtml','duplicate')])
make('casealias',base+[('epub/other','bad')])
make('dtd',[(p,'<!DOCTYPE container [<!ENTITY x SYSTEM "file:///etc/passwd">]>'+d if p=='META-INF/container.xml' else d) for p,d in base])
make('encrypted',base+[('META-INF/encryption.xml','<encryption/>')])
link=zipfile.ZipInfo('EPUB/link');link.create_system=3;link.external_attr=(stat.S_IFLNK|0o777)<<16
make('symlink',base+[(link,'../../outside')])
make('unknowncover',[(p,d.replace('properties="cover-image"','') if p=='EPUB/book.opf' else d) for p,d in base])
data=open(os.path.join(root,'safe.epub'),'rb').read();open(os.path.join(root,'truncated.epub'),'wb').write(data[:len(data)//2])
make('oversized',base+[('EPUB/huge','x'*200000)])
make('ratio',base+[('EPUB/huge','x'*3000000)])
make('windowsname',base+[('EPUB/CON.txt','bad')])
make('windowsunicode',base+[('EPUB/COM¹.txt','bad')])
make('wrongroot',[(p,d.replace('<package ','<random ').replace('</package>','</random>') if p=='EPUB/book.opf' else d) for p,d in base])
make('wrongnamespace',[(p,d.replace('http://www.idpf.org/2007/opf','urn:wrong') if p=='EPUB/book.opf' else d) for p,d in base])
make('wrongversion',[(p,d.replace('version="3.0"','version="9.0"') if p=='EPUB/book.opf' else d) for p,d in base])
make('entity',[(p,'<!ENTITY bad "bad">'+d if p=='EPUB/book.opf' else d) for p,d in base])
make('largeauthor',[(p,d.replace('Fixture author','a'*5000) if p=='EPUB/book.opf' else d) for p,d in base])
raw=bytearray(data)
# Flag encryption in both local and central records; do not encrypt fixture data.
for sig,offset in [(b'PK\x03\x04',6),(b'PK\x01\x02',8)]:
 pos=0
 while True:
  pos=raw.find(sig,pos)
  if pos<0:break
  raw[pos+offset]|=1;pos+=4
open(os.path.join(root,'encryptionflag.epub'),'wb').write(raw)
"""#
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/env"); process.arguments = ["python3", "-c", fixtureScript, temporary.path]
try process.run(); process.waitUntilExit(); precondition(process.terminationStatus == 0)
let fontManaged = temporary.appendingPathComponent("fonts-managed")
let fontImporter = EPUBPublicationImporter(directory: fontManaged)
for name in ["font", "fontshort"] {
    let source = temporary.appendingPathComponent(name + ".epub"), sourceBytes = try Data(contentsOf: source)
    let edition = try fontImporter.importPublication(from: source)
    let expected = Data((0..<(name == "font" ? 1500 : 17)).map { UInt8($0 % 251) })
    let actual = try Data(contentsOf: edition.directory.appendingPathComponent("resources/EPUB/font.otf"))
    precondition(actual == expected)
    let original = try Data(contentsOf: edition.directory.appendingPathComponent("original.epub"))
    let unchangedSource = try Data(contentsOf: source)
    precondition(original == sourceBytes && unchangedSource == sourceBytes)
    let duplicate = try fontImporter.importPublication(from: source); precondition(duplicate.alreadyImported)
}
for name in ["method", "remote", "traversal", "missing", "nonfont", "namespace", "duplicate", "transform", "base", "noid", "duplicateid", "wrongid", "blankid", "wrongnamespace"] {
    do { _ = try fontImporter.importPublication(from: temporary.appendingPathComponent("fontbad-" + name + ".epub")); fatalError("accepted unsafe font obfuscation: " + name) } catch {}
}
let fontEntries = try FileManager.default.contentsOfDirectory(atPath: fontManaged.path)
precondition(fontEntries.count == 2 && !fontEntries.contains { $0.hasPrefix(".import-") })
print("epub-import-smoke: IDPF known SHA1 vector, XML whitespace, short/1040-byte prefix boundary, original preservation and font rejection cleanup passed")
let adobeImporter = EPUBPublicationImporter(directory: temporary.appendingPathComponent("adobe-managed"))
let adobe = try adobeImporter.importPublication(from: temporary.appendingPathComponent("adobefont.epub"))
let adobePlain = Data(Array("OTTO".utf8) + (0..<2000).map { UInt8($0 % 249) })
let adobeFont = try Data(contentsOf: adobe.directory.appendingPathComponent("resources/EPUB/font.otf"))
precondition(adobeFont == adobePlain)
let noise = try adobeImporter.importPublication(from: temporary.appendingPathComponent("adobenoise.epub"))
let noiseFont = try Data(contentsOf: noise.directory.appendingPathComponent("resources/EPUB/font.otf"))
precondition(noiseFont != adobePlain && noiseFont.count == adobePlain.count, "a wrong Adobe key must leave the font as it was")
print("epub-import-smoke: Adobe urn:uuid font de-obfuscation beside an ISBN, legacy font type, and wrong-key fonts left untouched passed")
let managed = temporary.appendingPathComponent("managed")
let importer = EPUBPublicationImporter(directory: managed)
let source = temporary.appendingPathComponent("safe.epub"), before = try Data(contentsOf: source)
let first = try importer.importPublication(from: source)
precondition(!first.alreadyImported && first.publication.title == "Fixture title" && first.publication.authors == ["Fixture author"])
precondition(first.publication.coverPath == "EPUB/cover.png" && first.publication.spine == ["EPUB/chapter.xhtml"])
let after = try Data(contentsOf: source); precondition(after == before)
let copied = try Data(contentsOf: first.directory.appendingPathComponent("original.epub")); precondition(copied == before)
let again = try importer.importPublication(from: source)
precondition(again.alreadyImported && again.publication.id == first.publication.id)
for name in ["traversal", "absolute", "backslash", "duplicate", "casealias", "dtd", "encrypted", "symlink", "truncated", "ratio", "windowsname", "entity", "largeauthor", "encryptionflag", "windowsunicode", "wrongroot", "wrongnamespace", "wrongversion", "badlanguage", "baddirection", "navremote", "navtraversal", "navunknown", "navdtdsubset", "navtwodoctypes"] {
    do { _ = try importer.importPublication(from: temporary.appendingPathComponent(name + ".epub")); fatalError("accepted hostile fixture: " + name) }
    catch { print("rejected \(name): \(error.localizedDescription)") }
}
let navImporter = EPUBPublicationImporter(directory: temporary.appendingPathComponent("navigation-managed"))
let navEdition = try navImporter.importPublication(from: temporary.appendingPathComponent("navigation.epub"))
precondition(navEdition.publication.toc?.first?.title == "Part & One")
precondition(navEdition.publication.toc?.first?.children?.first?.title == "A nested note")
precondition(navEdition.publication.toc?.first?.children?.first?.href == "EPUB/chapter.xhtml#fn1")
precondition(navEdition.publication.landmarks?.first?.title == "Begin reading" && navEdition.publication.pageList?.first?.href == "EPUB/chapter.xhtml#page7")
let ncxEdition = try navImporter.importPublication(from: temporary.appendingPathComponent("ncx.epub"))
precondition(ncxEdition.publication.toc?.first?.title == "Chapter & title")
precondition(ncxEdition.publication.toc?.first?.children?.first?.href == "EPUB/chapter.xhtml#fn1")
precondition(ncxEdition.publication.landmarks?.first?.title == "Start & read" && ncxEdition.publication.pageList?.first?.title == "7")
let alternatePrefix = try navImporter.importPublication(from: temporary.appendingPathComponent("navprefix.epub"))
precondition(alternatePrefix.publication.toc?.first?.title == "Part & One")
let doctypeImporter = EPUBPublicationImporter(directory: temporary.appendingPathComponent("doctype-managed"))
let ncxDoctype = try doctypeImporter.importPublication(from: temporary.appendingPathComponent("ncxdoctype.epub"))
precondition(ncxDoctype.publication.toc?.first?.title == "Chapter & title", "EPUB 2 NCX with its standard DOCTYPE")
let navDoctype = try doctypeImporter.importPublication(from: temporary.appendingPathComponent("navdoctype.epub"))
precondition(navDoctype.publication.toc?.first?.title == "Part & One", "EPUB 3 navigation with <!DOCTYPE html>")
let recoveredNav = try navImporter.loadLibrary()
precondition(recoveredNav.count == 3)
var oldNav = try JSONSerialization.jsonObject(with: JSONEncoder().encode(navEdition.publication)) as! [String: Any]
for key in ["toc", "landmarks", "pageList"] { oldNav.removeValue(forKey: key) }
let legacyNavigation = try JSONDecoder().decode(EPUBPublication.self, from: JSONSerialization.data(withJSONObject: oldNav))
precondition(legacyNavigation.toc == nil && legacyNavigation.landmarks == nil && legacyNavigation.pageList == nil)
let receiptWithNavigation = navEdition.directory.appendingPathComponent("publication.json")
var badNavigation = navEdition.publication; badNavigation.toc = [EPUBNavigationLink(href: "https://example.com", title: "Remote")]
try JSONEncoder().encode(badNavigation).write(to: receiptWithNavigation)
do { _ = try navImporter.loadLibrary(); fatalError("accepted unsafe navigation receipt") } catch {}
try JSONEncoder().encode(navEdition.publication).write(to: receiptWithNavigation)
let noCover = try importer.importPublication(from: temporary.appendingPathComponent("unknowncover.epub"))
precondition(noCover.publication.coverPath == nil)
var limits = EPUBPublicationImporter.Limits(); limits.resourceBytes = 100000
let bounded = EPUBPublicationImporter(directory: temporary.appendingPathComponent("bounded"), limits: limits)
do { _ = try bounded.importPublication(from: temporary.appendingPathComponent("oversized.epub")); fatalError("accepted oversized") } catch {}
let fixed = try importer.importPublication(from: temporary.appendingPathComponent("fixedlayout.epub"))
precondition(fixed.publication.layout == "pre-paginated")
let nonlinear = try importer.importPublication(from: temporary.appendingPathComponent("nonlinear.epub"))
precondition(nonlinear.publication.layout == "reflowable")
precondition(nonlinear.publication.spine == ["EPUB/chapter.xhtml"] && nonlinear.publication.resources.contains(where: { $0.path == "EPUB/appendix.xhtml" }))
let rtl = try importer.importPublication(from: temporary.appendingPathComponent("rtl.epub"))
precondition(rtl.publication.languages == ["ar", "en-US"] && rtl.publication.readingProgression == "rtl")
precondition(first.publication.languages == nil && first.publication.readingProgression == nil)
var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(rtl.publication)) as! [String: Any]
legacy.removeValue(forKey: "languages"); legacy.removeValue(forKey: "readingProgression")
let decodedLegacy = try JSONDecoder().decode(EPUBPublication.self, from: JSONSerialization.data(withJSONObject: legacy))
precondition(decodedLegacy.languages == nil && decodedLegacy.readingProgression == nil)
let library = try importer.loadLibrary(); precondition(library.count == 5)
let receiptURL = rtl.directory.appendingPathComponent("publication.json")
var badReceipt = rtl.publication; badReceipt.languages = [String(repeating: "x", count: 129)]
try JSONEncoder().encode(badReceipt).write(to: receiptURL)
do { _ = try importer.loadLibrary(); fatalError("accepted overlong receipt language") } catch {}
badReceipt = rtl.publication; badReceipt.readingProgression = "vertical"
try JSONEncoder().encode(badReceipt).write(to: receiptURL)
do { _ = try importer.loadLibrary(); fatalError("accepted invalid receipt progression") } catch {}
try JSONEncoder().encode(rtl.publication).write(to: receiptURL)
let children = try FileManager.default.contentsOfDirectory(atPath: managed.path)
precondition(!children.contains(where: { $0.hasPrefix(".import-") }))
let managedOriginal = first.directory.appendingPathComponent("original.epub")
try Data("corrupted".utf8).write(to: managedOriginal)
do { _ = try importer.loadLibrary(); fatalError("accepted corrupted original receipt") } catch {}
do { _ = try importer.importPublication(from: source); fatalError("accepted corrupted duplicate original") } catch {}
let recovered = try importer.recoverLibrary()
precondition(recovered.publications.count == 4 && recovered.failedCount == 1 && recovered.warnings.count == 1)
precondition(!recovered.publications.contains(where: { $0.publication.id == first.publication.id }))
let corruptBytes = try Data(contentsOf: managedOriginal); precondition(corruptBytes == Data("corrupted".utf8))
try before.write(to: managedOriginal)
let resource = first.directory.appendingPathComponent("resources/EPUB/chapter.xhtml")
try FileManager.default.removeItem(at: resource)
try FileManager.default.createSymbolicLink(at: resource, withDestinationURL: source)
do { _ = try importer.loadLibrary(); fatalError("accepted linked resource receipt") } catch {}
do { _ = try importer.importPublication(from: source); fatalError("accepted linked duplicate receipt") } catch {}
for index in 0..<25 {
    let invalidID = String(format: "%064x", index)
    try FileManager.default.createDirectory(at: managed.appendingPathComponent(invalidID), withIntermediateDirectories: true)
}
let boundedRecovery = try importer.recoverLibrary()
precondition(boundedRecovery.publications.count == 4 && boundedRecovery.failedCount == 26 && boundedRecovery.warnings.count == 20)
precondition(boundedRecovery.warnings.allSatisfy { $0.count <= 512 })
print("epub-import-smoke: safe import, original preservation, dedupe, explicit covers, hostile archives, bounded expansion and cleanup passed")
