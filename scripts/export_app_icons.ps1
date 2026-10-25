param([string]$OutputDirectory = (Join-Path $PSScriptRoot '../output/app-icons'))

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)

# Deterministic export/packaging of approved artwork. No generative redraws.
# The approved imagegen reference lives in output/app-icons/source.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

public static class AppIconExport {
    static readonly int[] Sizes = {16,20,24,32,40,48,64,256};
    static readonly string[] Density = {"mdpi","hdpi","xhdpi","xxhdpi","xxxhdpi"};
    static readonly int[] Legacy = {48,72,96,144,192};
    static readonly int[] Adaptive = {108,162,216,324,432};
    static readonly int[] Notification = {24,36,48,72,96};
    static readonly Color Ivory = Color.FromArgb(248,237,216);
    static readonly Color Gold = Color.FromArgb(205,173,109);
    static readonly Color Navy = Color.FromArgb(8,25,43);
    static string Root;

    static Bitmap Canvas(int n) { return new Bitmap(n,n,PixelFormat.Format32bppArgb); }
    static Graphics Context(Bitmap b) {
        Graphics g = Graphics.FromImage(b);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        return g;
    }
    static void Save(Bitmap b, string path) {
        Directory.CreateDirectory(Path.GetDirectoryName(path));
        b.Save(path,ImageFormat.Png);
    }
    static Bitmap Resize(Bitmap b,int n) {
        Bitmap r=Canvas(n);
        using(Graphics g=Context(r)) {
            using(ImageAttributes attrs=new ImageAttributes()) {
                attrs.SetWrapMode(WrapMode.TileFlipXY);
                g.DrawImage(b,new Rectangle(0,0,n,n),0,0,b.Width,b.Height,GraphicsUnit.Pixel,attrs);
            }
        }
        return r;
    }
    static Bitmap Background(int n,bool gaia) {
        Bitmap b=Canvas(n);
        using(Graphics g=Context(b))
        using(LinearGradientBrush brush=new LinearGradientBrush(new Point(0,0),new Point(0,n),gaia?Color.FromArgb(132,12,23):Color.FromArgb(20,46,68),gaia?Color.FromArgb(37,1,6):Color.FromArgb(4,18,35)))
            g.FillRectangle(brush,0,0,n,n);
        return b;
    }
    static GraphicsPath Rounded(int n) {
        float d=n*0.32f;
        GraphicsPath p=new GraphicsPath();
        p.AddArc(0,0,d,d,180,90); p.AddArc(n-d,0,d,d,270,90);
        p.AddArc(n-d,n-d,d,d,0,90); p.AddArc(0,n-d,d,d,90,90); p.CloseFigure();
        return p;
    }
    static Bitmap RoundedTile(Bitmap b) {
        Bitmap result=Canvas(b.Width);
        using(Graphics g=Context(result))
        using(GraphicsPath p=Rounded(b.Width))
        using(TextureBrush brush=new TextureBrush(b)) g.FillPath(brush,p);
        return result;
    }
    static Bitmap Extract(string file,bool gaia) {
        // Restrict extraction to the artwork region, excluding all labels,
        // sheet margins and rounded-tile corners. Navy structural cutouts
        // become transparency, allowing real adaptive foreground layers.
        Bitmap art=Canvas(768);
        using(Bitmap sheet=new Bitmap(file)) {
            int tileX=gaia?904:105;
            int left=gaia?950:130, right=gaia?1620:780;
            for(int y=120;y<662;y++) for(int x=left;x<right;x++) {
                Color c=sheet.GetPixel(x,y);
                if((gaia?c.G:c.R)<43) continue;
                double t=(y-45)/728.0;
                double br=20-16*t, bg=46-28*t, bb=68-33*t;
                if(gaia) {
                    Color backdrop=sheet.GetPixel(935,y);
                    br=backdrop.R; bg=backdrop.G; bb=backdrop.B;
                }
                double a=Math.Max(0,Math.Min(1,gaia?(c.G-bg)/(110-bg):(c.R-br)/(110-br)));
                if(a<0.025) continue;
                int rr=(int)Math.Round((c.R-(1-a)*br)/a);
                int gg=(int)Math.Round((c.G-(1-a)*bg)/a);
                int bl=(int)Math.Round((c.B-(1-a)*bb)/a);
                art.SetPixel(x-tileX,y-25,Color.FromArgb((int)Math.Round(a*255),Clamp(rr),Clamp(gg),Clamp(bl)));
            }
        }
        return art;
    }
    static int Clamp(int c) { return Math.Max(0,Math.Min(255,c)); }
    static Rectangle Bounds(Bitmap b) {
        int l=b.Width,t=b.Height,r=0,bot=0;
        for(int y=0;y<b.Height;y++) for(int x=0;x<b.Width;x++)
            if(b.GetPixel(x,y).A>8) {l=Math.Min(l,x);r=Math.Max(r,x);t=Math.Min(t,y);bot=Math.Max(bot,y);}
        return Rectangle.FromLTRB(l,t,r+1,bot+1);
    }
    static Bitmap SafeLayer(Bitmap art,int n) {
        Rectangle bounds=Bounds(art);
        float cx=bounds.Left+bounds.Width/2f, cy=bounds.Top+bounds.Height/2f;
        double radius=0;
        for(int y=bounds.Top;y<bounds.Bottom;y++) for(int x=bounds.Left;x<bounds.Right;x++)
            if(art.GetPixel(x,y).A>8) radius=Math.Max(radius,Math.Sqrt((x-cx)*(x-cx)+(y-cy)*(y-cy)));
        // Entire composition, including star and booms, inside a 64dp circle
        // on a 108dp layer; 1dp guard within Android's 66dp safe circle.
        float scale=(float)((32.0/108)*n/radius);
        Bitmap layer=Canvas(n);
        using(Graphics g=Context(layer))
            g.DrawImage(art,new RectangleF(n/2f-cx*scale,n/2f-cy*scale,art.Width*scale,art.Height*scale));
        return layer;
    }
    static void Polygon(Graphics g,Color c,params float[] xy) {
        PointF[] points=new PointF[xy.Length/2];
        for(int i=0;i<points.Length;i++) points[i]=new PointF(xy[i*2],xy[i*2+1]);
        using(Brush b=new SolidBrush(c)) g.FillPolygon(b,points);
    }
    static void Ellipse(Graphics g,Color c,float x,float y,float w,float h) {
        using(Brush b=new SolidBrush(c)) g.FillEllipse(b,x,y,w,h);
    }
    static void Line(Graphics g,Color c,float width,float x1,float y1,float x2,float y2) {
        using(Pen p=new Pen(c,width)) {p.StartCap=LineCap.Round;p.EndCap=LineCap.Round;g.DrawLine(p,x1,y1,x2,y2);}
    }
    static Bitmap SimpleArt(bool gaia,bool mono,bool star,int n) {
        Bitmap b=Canvas(n);
        using(Graphics g=Context(b)) {
            g.ScaleTransform(n/256f,n/256f);
            Color fill=mono?Color.White:Ivory, accent=mono?Color.White:Gold;
            Color cut=mono?Color.Transparent:Navy;
            if(mono) g.CompositingMode=CompositingMode.SourceCopy;
            if(star) Polygon(g,Color.White,128,25,132,36,143,40,132,44,128,55,124,44,113,40,124,36);
            if(!gaia) {
                // Deliberately thicker booms and feed supports for tiny sizes.
                Line(g,fill,6,110,171,36,212); Line(g,accent,7,149,171,211,202);
                Polygon(g,accent,204,190,224,197,219,214,199,207);
                Polygon(g,accent,105,143,151,143,148,179,109,179);
                Polygon(g,fill,113,151,144,151,144,174,113,174);
                Polygon(g,cut,123,157,134,157,134,167,123,167);
                using(GraphicsPath dish=new GraphicsPath()) {
                    dish.AddBezier(42,112,59,168,198,168,214,112);
                    dish.AddLine(214,112,42,112);
                    using(Brush br=new SolidBrush(accent)) g.FillPath(br,dish);
                }
                Ellipse(g,fill,42,88,172,50);
                Line(g,cut,5,103,110,128,75); Line(g,cut,5,153,110,128,75);
                Line(g,accent,5,128,110,128,77); Ellipse(g,accent,121,65,14,17);
            } else {
                // Same tilted broad sunshield/body silhouette as approved G8.
                GraphicsState state=g.Save();
                g.TranslateTransform(128,158);g.RotateTransform(17);g.TranslateTransform(-128,-158);
                Ellipse(g,fill,25,122,207,78);
                Line(g,cut,4,128,150,42,132); Line(g,cut,4,128,150,56,187);
                Line(g,cut,4,128,150,145,199); Line(g,cut,4,128,150,224,171);
                Polygon(g,fill,91,95,112,80,156,80,174,97,174,151,94,151);
                Polygon(g,accent,91,95,112,80,156,80,174,97);
                Polygon(g,cut,98,103,118,107,118,122,98,118);
                Line(g,cut,4,94,150,174,150);
                g.Restore(state);
            }
        }
        return b;
    }
    static void Whiten(Bitmap b) {
        for(int y=0;y<b.Height;y++) for(int x=0;x<b.Width;x++) {
            int a=b.GetPixel(x,y).A;
            b.SetPixel(x,y,Color.FromArgb(a,255,255,255));
        }
    }
    static Bitmap Composite(Bitmap foreground,int n,bool gaia) {
        Bitmap result=Background(n,gaia);
        using(Graphics g=Context(result)) g.DrawImage(foreground,0,0,n,n);
        return result;
    }
    static void WriteIco(string path,List<Bitmap> frames) {
        List<byte[]> data=new List<byte[]>();
        foreach(Bitmap b in frames) using(MemoryStream ms=new MemoryStream()) {b.Save(ms,ImageFormat.Png);data.Add(ms.ToArray());}
        using(BinaryWriter w=new BinaryWriter(File.Create(path))) {
            w.Write((ushort)0);w.Write((ushort)1);w.Write((ushort)frames.Count);
            int offset=6+16*frames.Count;
            for(int i=0;i<frames.Count;i++) {
                int n=frames[i].Width;
                w.Write((byte)(n==256?0:n));w.Write((byte)(n==256?0:n));w.Write((byte)0);w.Write((byte)0);
                w.Write((ushort)1);w.Write((ushort)32);w.Write(data[i].Length);w.Write(offset);offset+=data[i].Length;
            }
            foreach(byte[] bytes in data) w.Write(bytes);
        }
    }
    static void Text(string path,string content) { Directory.CreateDirectory(Path.GetDirectoryName(path));File.WriteAllText(path,content+"\n",new System.Text.UTF8Encoding(false)); }
    static string AdaptiveXml(string name,bool mono) {
        return "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<adaptive-icon xmlns:android=\"http://schemas.android.com/apk/res/android\">\n    <background android:drawable=\"@drawable/"+name+"_background\" />\n    <foreground android:drawable=\"@mipmap/"+name+"_foreground\" />\n"+(mono?"    <monochrome android:drawable=\"@mipmap/"+name+"_monochrome\" />\n":"")+"</adaptive-icon>";
    }
    static void Export(bool gaia) {
        string app=gaia?"gaia":"voyager", name=gaia?"ic_gaia":"ic_launcher";
        string dir=Path.Combine(Root,app), res=Path.Combine(dir,"android/res");
        Directory.CreateDirectory(Path.Combine(dir,"windows/png"));
        string source=Path.Combine(Root,"source","approved-white-stars-red-gaia-pair.png");
        using(Bitmap art=Extract(source,gaia))
        using(Bitmap full=Composite(art,1024,gaia))
        using(Bitmap simple=SimpleArt(gaia,false,true,1024))
        using(Bitmap monoArt=SimpleArt(gaia,true,true,768))
        using(Bitmap notifyArt=SimpleArt(gaia,true,false,768)) {
            using(Bitmap f=Resize(art,1024)) Save(f,Path.Combine(dir,"masters/foreground-1024.png"));
            using(Bitmap bg=Background(1024,gaia)) Save(bg,Path.Combine(dir,"masters/background-1024.png"));
            Save(full,Path.Combine(dir,"masters/icon-1024.png"));
            using(Bitmap store=Resize(full,512)) Save(store,Path.Combine(dir,"store/icon-512.png"));
            using(Bitmap adaptive=SafeLayer(art,432)) Save(adaptive,Path.Combine(dir,"masters/adaptive-foreground-432.png"));
            List<Bitmap> frames=new List<Bitmap>();
            foreach(int n in Sizes) {
                // Dedicated simplified drawing at 16,20,24 instead of shrinking
                // thin mechanical details from the large illustration.
                using(Bitmap tile=n<=24?Composite(simple,1024,gaia):(Bitmap)full.Clone())
                using(Bitmap rounded=RoundedTile(tile)) {
                    Bitmap frame=Resize(rounded,n);
                    // Remove the faint bicubic alpha fringe at tiny tile corners.
                    for(int fy=0;fy<n;fy++) for(int fx=0;fx<n;fx++)
                        if(frame.GetPixel(fx,fy).A<16) frame.SetPixel(fx,fy,Color.Transparent);
                    frames.Add(frame);
                    Save(frame,Path.Combine(dir,"windows/png/icon-"+n+".png"));
                }
            }
            WriteIco(Path.Combine(dir,"windows/"+app+".ico"),frames);
            foreach(Bitmap frame in frames) frame.Dispose();
            for(int d=0;d<Density.Length;d++) {
                string mip=Path.Combine(res,"mipmap-"+Density[d]);
                using(Bitmap legacy=Resize(full,Legacy[d])) Save(legacy,Path.Combine(mip,name+".png"));
                using(Bitmap foreground=SafeLayer(art,Adaptive[d])) Save(foreground,Path.Combine(mip,name+"_foreground.png"));
                using(Bitmap bg=Background(Adaptive[d],gaia)) Save(bg,Path.Combine(mip,name+"_background.png"));
                using(Bitmap mono=SafeLayer(monoArt,Adaptive[d])) {
                    Whiten(mono);Save(mono,Path.Combine(mip,name+"_monochrome.png"));
                }
                using(Bitmap notification=Resize(notifyArt,Notification[d])) {
                    Whiten(notification);
                    Save(notification,Path.Combine(res,"drawable-"+Density[d]+"/ic_stat_"+app+".png"));
                }
            }
            // Drawable aliases preserve density-aware PNG backgrounds while
            // keeping adaptive XML compatible with the conventional layout.
            Text(Path.Combine(res,"values/"+app+"_icon_background.xml"),"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<resources>\n    <item name=\""+name+"_background\" type=\"drawable\">@mipmap/"+name+"_background</item>\n</resources>");
            Text(Path.Combine(res,"mipmap-anydpi-v26/"+name+".xml"),AdaptiveXml(name,false));
            Text(Path.Combine(res,"mipmap-anydpi-v33/"+name+".xml"),AdaptiveXml(name,true));
            Text(Path.Combine(res,"mipmap-anydpi-v26/"+name+"_round.xml"),AdaptiveXml(name,false));
            Text(Path.Combine(res,"mipmap-anydpi-v33/"+name+"_round.xml"),AdaptiveXml(name,true));
            for(int d=0;d<Density.Length;d++) {
                using(Bitmap safeForeground=SafeLayer(art,432))
                using(Bitmap safeBackground=Background(432,gaia))
                using(Bitmap circle=Canvas(Legacy[d])) {
                    using(Graphics sg=Context(safeBackground)) sg.DrawImageUnscaled(safeForeground,0,0);
                    using(Bitmap viewport=safeBackground.Clone(new Rectangle(72,72,288,288),PixelFormat.Format32bppArgb))
                    using(Bitmap tile=Resize(viewport,Legacy[d]))
                    using(Graphics g=Context(circle)) using(TextureBrush brush=new TextureBrush(tile))
                        g.FillEllipse(brush,0,0,circle.Width,circle.Height);
                    Save(circle,Path.Combine(res,"mipmap-"+Density[d]+"/"+name+"_round.png"));
                }
            }
        }
    }
    static void Preview() {
        using(Bitmap page=new Bitmap(1500,1130,PixelFormat.Format32bppArgb))
        using(Graphics g=Context(page))
        using(Font title=new Font("Segoe UI",22,FontStyle.Bold))
        using(Font label=new Font("Segoe UI",12))
        using(Brush ink=new SolidBrush(Color.FromArgb(30,45,62))) {
            g.Clear(Color.FromArgb(247,245,240));
            g.DrawString("Voyager + Gaia / production icon assets",title,ink,40,22);
            for(int app=0;app<2;app++) {
                string name=app==0?"voyager":"gaia"; int x=40+app*740;
                g.DrawString(app==0?"VOYAGER":"GAIA",label,ink,x,78);
                using(Bitmap master=new Bitmap(Path.Combine(Root,name,"masters/icon-1024.png")))
                using(Bitmap rounded=RoundedTile(master)) g.DrawImage(rounded,x,110,320,320);
                g.DrawString("Windows: native pixels + 4x magnification",label,ink,x,458);
                int pos=x, zoomPos=x;
                foreach(int n in Sizes) {
                    if(n==256) continue;
                    using(Bitmap icon=new Bitmap(Path.Combine(Root,name,"windows/png/icon-"+n+".png"))) {
                        g.DrawImageUnscaled(icon,pos,490);
                        if(n<=32) {
                            g.InterpolationMode=InterpolationMode.NearestNeighbor;g.PixelOffsetMode=PixelOffsetMode.Half;
                            g.DrawImage(icon,new Rectangle(zoomPos,590,n*4,n*4));
                            g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.PixelOffsetMode=PixelOffsetMode.HighQuality;
                            zoomPos+=n*4+24;
                        }
                    }
                    g.DrawString(n.ToString(),label,ink,pos,558);pos+=n+32;
                }
                g.DrawString("Android adaptive: circle / rounded / themed",label,ink,x,742);
                using(Bitmap fg=new Bitmap(Path.Combine(Root,name,"masters/adaptive-foreground-432.png")))
                using(Bitmap bg=Background(432,app==1)) {
                    using(Graphics cg=Context(bg)) cg.DrawImageUnscaled(fg,0,0);
                    // Launcher viewport is central 72dp of the 108dp layers.
                    using(Bitmap viewport=bg.Clone(new Rectangle(72,72,288,288),PixelFormat.Format32bppArgb))
                    using(Bitmap small=Resize(viewport,150)) {
                        using(TextureBrush brush=new TextureBrush(small)) {
                            GraphicsState s=g.Save();g.TranslateTransform(x,785);g.FillEllipse(brush,0,0,150,150);g.Restore(s);
                        }
                        using(Bitmap round=RoundedTile(small)) g.DrawImageUnscaled(round,x+178,785);
                    }
                }
                string m=app==0?"ic_launcher":"ic_gaia";
                using(Bitmap mono=new Bitmap(Path.Combine(Root,name,"android/res/mipmap-xxxhdpi/"+m+"_monochrome.png")))
                using(Bitmap themed=new Bitmap(432,432,PixelFormat.Format32bppArgb)) {
                    using(Graphics cg=Context(themed)) {
                        cg.Clear(Color.FromArgb(63,75,60));cg.DrawImageUnscaled(mono,0,0);
                    }
                    using(Bitmap crop=themed.Clone(new Rectangle(72,72,288,288),PixelFormat.Format32bppArgb))
                    using(Bitmap mini=Resize(crop,150))
                    using(Bitmap rounded=RoundedTile(mini)) g.DrawImageUnscaled(rounded,x+356,785);
                }
                g.DrawString("Notification: 24px native / 4x magnification",label,ink,x,965);
                using(Bitmap notif=new Bitmap(Path.Combine(Root,name,"android/res/drawable-mdpi/ic_stat_"+name+".png"))) {
                    g.FillRectangle(Brushes.DarkSlateGray,x,1000,160,106);g.DrawImageUnscaled(notif,x+9,1012);
                    g.InterpolationMode=InterpolationMode.NearestNeighbor;g.PixelOffsetMode=PixelOffsetMode.Half;
                    g.DrawImage(notif,new Rectangle(x+52,1004,96,96));
                    g.InterpolationMode=InterpolationMode.HighQualityBicubic;g.PixelOffsetMode=PixelOffsetMode.HighQuality;
                }
            }
            Save(page,Path.Combine(Root,"preview.png"));
        }
    }
    public static void Run(string root) { Root=root; Export(false);Export(true);Preview(); }
}
'@

[AppIconExport]::Run($OutputDirectory)
Write-Output "Exported icon sets and preview to $OutputDirectory"
