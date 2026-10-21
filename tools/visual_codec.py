"""Shared Inventory Redux modular BAM V2/BC3 codec, reused for BuffBot visual assets. Offline only."""
from pathlib import Path
import hashlib,io,json,math,struct,zlib
from PIL import Image
import numpy as np

PAGE_SIZE=1024

def alpha_blocks(image,body):
    """BC3 alpha endpoints/48-bit indices, independently optimized per block.
    Unlike RGB, alpha endpoints0/255 must remain exact wherever present.
    """
    pixels=np.asarray(image,dtype=np.uint8)[:,:,3]
    a=pixels.reshape(image.height//4,4,image.width//4,4).transpose(0,2,1,3).reshape(-1,16).astype(np.int32)
    lo=a.min(1);hi=a.max(1)
    interior_lo=np.where(a>0,a,255).min(1);interior_hi=np.where(a<255,a,0).max(1)
    pairs=[(hi,lo),(lo,hi),(interior_lo,interior_hi),(interior_hi,interior_lo)]
    best_score=np.full(len(a),2**60,dtype=np.int64);best=np.zeros((len(a),8),dtype=np.uint8)
    shifts=np.arange(16,dtype=np.uint64)*3
    for p,q in pairs:
        pal=np.empty((len(a),8),dtype=np.int32);pal[:,0]=p;pal[:,1]=q;high=p>q
        for k in range(1,7):
            pal[:,k+1]=np.where(high,((7-k)*p+k*q)//7,((5-k)*p+k*q)//5 if k<5 else (0 if k==5 else 255))
        diff=np.abs(a[:,:,None]-pal[:,None,:]);index=diff.argmin(2)
        err=np.take_along_axis(diff,index[:,:,None],2)[:,:,0]
        score=(err.astype(np.int64)**2).sum(1)
        # Never optimize away exact transparent/opaque source pixels.
        score[((a==0).any(1)&~(pal==0).any(1))|((a==255).any(1)&~(pal==255).any(1))]=2**60
        take=score<best_score
        packed=(index.astype(np.uint64)<<shifts).sum(1)
        encoded=np.empty((len(a),8),dtype=np.uint8);encoded[:,0]=p;encoded[:,1]=q
        for k in range(6):encoded[:,k+2]=(packed>>(8*k))&255
        best[take]=encoded[take];best_score[take]=score[take]
    if (best_score==2**60).any():raise ValueError('BC3 alpha candidate failure')
    blocks=np.frombuffer(body,dtype=np.uint8).copy().reshape(-1,16);blocks[:,:8]=best
    return blocks.tobytes()

def encode_page(image):
    if image.mode!='RGBA' or not 0<image.width<=PAGE_SIZE or not 0<image.height<=PAGE_SIZE:
        raise ValueError('RGBA page bounds')
    # Match the game's native texture pages. Keep content at its original
    # dimensions; only the transparent GPU allocation is padded.
    w,h=max(4,1<<(image.width-1).bit_length()),max(4,1<<(image.height-1).bit_length())
    padded=Image.new('RGBA',(w,h));padded.paste(image,(0,0))
    stream=io.BytesIO();padded.save(stream,format='DDS',pixel_format='DXT5')
    dds=stream.getvalue()
    if dds[:4]!=b'DDS ' or dds[84:88]!=b'DXT5' or len(dds)!=128+w*h:raise ValueError('DDS DXT5 writer contract')
    # PVR v3: compressed pixel format11=BC3/DXT5, linear colourspace,
    # unsigned-normalized channels, one surface/face/mip and no metadata.
    pvr=struct.pack('<IIQ9I',0x03525650,0,11,0,0,h,w,1,1,1,1,0)+alpha_blocks(padded,dds[128:])
    return struct.pack('<I',len(pvr))+zlib.compress(pvr,9)

def decode_page(data):
    if len(data)<5:raise ValueError('PVRZ prefix')
    size=struct.unpack_from('<I',data)[0]
    if size<52 or size>52+PAGE_SIZE*PAGE_SIZE:raise ValueError('PVRZ decoded bound')
    dec=zlib.decompressobj();p=dec.decompress(data[4:],size+1)
    if len(p)!=size or not dec.eof or dec.unused_data or dec.unconsumed_tail:raise ValueError('PVRZ exact stream')
    v,flags,fmt,colour,channel,h,w,depth,surfaces,faces,mips,meta=struct.unpack_from('<IIQ9I',p)
    if (v,flags,fmt,colour,channel,depth,surfaces,faces,mips,meta)!=(0x03525650,0,11,0,0,1,1,1,1,0):raise ValueError('PVR format')
    if not 0<w<=PAGE_SIZE or not 0<h<=PAGE_SIZE or w%4 or h%4 or len(p)!=52+w*h:raise ValueError('PVR geometry')
    hdr=[124,0x81007,h,w,w*h,0,1]+[0]*11+[32,4,int.from_bytes(b'DXT5','little'),0,0,0,0,0]+[0x1000,0,0,0,0]
    return Image.open(io.BytesIO(b'DDS '+struct.pack('<31I',*hdr)+p[52:])).convert('RGBA')

def encode_bam(image,first_page):
    if image.mode!='RGBA' or not 0<image.width<=32767 or not 0<image.height<=32767:raise ValueError('BAM dimensions')
    blocks=[];pages={}
    for y in range(0,image.height,PAGE_SIZE):
        for x in range(0,image.width,PAGE_SIZE):
            page=first_page+len(blocks)
            if not 0<=page<=99999:raise ValueError('8-character MOS page resref')
            w,h=min(PAGE_SIZE,image.width-x),min(PAGE_SIZE,image.height-y)
            pages[page]=encode_page(image.crop((x,y,x+w,y+h)))
            blocks.append(struct.pack('<7I',page,0,0,w,h,x,y))
    header=b'BAM V2  '+struct.pack('<6I',1,1,len(blocks),32,44,48)
    frame=struct.pack('<HHhhHH',image.width,image.height,0,0,0,len(blocks))
    return header+frame+struct.pack('<HH',1,0)+b''.join(blocks),pages

def decode_bam(data,pages):
    if len(data)<48 or data[:8]!=b'BAM V2  ':raise ValueError('BAM signature')
    nf,nc,nb,fo,co,bo=struct.unpack_from('<6I',data,8)
    if (nf,nc,fo,co,bo)!=(1,1,32,44,48) or not nb or len(data)!=48+28*nb:raise ValueError('single modular frame contract')
    w,h,cx,cy,start,count=struct.unpack_from('<HHhhHH',data,fo)
    if not w or not h or cx or cy or start or count!=nb or struct.unpack_from('<HH',data,co)!=(1,0):raise ValueError('frame/cycle contract')
    result=Image.new('RGBA',(w,h));area=0;rects=[]
    for n in range(nb):
        page,x,y,bw,bh,tx,ty=struct.unpack_from('<7I',data,bo+28*n)
        if not bw or not bh or tx+bw>w or ty+bh>h:raise ValueError('block destination')
        for a,b,c,d in rects:
            if tx<a+c and a<tx+bw and ty<b+d and b<ty+bh:raise ValueError('block overlap')
        rects.append((tx,ty,bw,bh));area+=bw*bh
        decoded=decode_page(pages[page])
        if x+bw>decoded.width or y+bh>decoded.height:raise ValueError('block source')
        result.paste(decoded.crop((x,y,x+bw,y+bh)),(tx,ty))
    if area!=w*h:raise ValueError('incomplete frame')
    return result

def quality(original,decoded):
    if original.size!=decoded.size:raise ValueError('roundtrip size')
    a=np.asarray(original,dtype=np.int32);b=np.asarray(decoded,dtype=np.int32);diff=np.abs(a-b)
    weight=int(a[:,:,3].sum())*3
    return {'alphaMaxError':int(diff[:,:,3].max()),'alphaMeanError':float(diff[:,:,3].mean()),
            'visibleRgbMeanError':float((diff[:,:,:3]*a[:,:,3,None]).sum()/weight) if weight else 0,
            'transparentPixelsChanged':int(((a[:,:,3]==0)&(b[:,:,3]!=0)).sum()),
            'opaquePixelsChanged':int(((a[:,:,3]==255)&(b[:,:,3]!=255)).sum())}
