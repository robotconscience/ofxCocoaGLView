#include "ofMain.h"

#include "ofxCocoaGLView.h"
#include "ofAppBaseWindow.h"

#define BEGIN_OPENGL() \
[[self openGLContext] makeCurrentContext]; \
CGLContextObj cglContext = (CGLContextObj)[[self openGLContext] CGLContextObj]; \
CGLLockContext(cglContext);

#define END_OPENGL() \
CGLUnlockContext(cglContext);

#define OFXCOCOAGLVIEW_IGNORED ofLogWarning("ofxCocoaGLView") << "operation ignored";

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,  const CVTimeStamp* now, const CVTimeStamp* outputTime, CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext);

class ofxCocoaGLViewWindowProxy : public ofAppBaseWindow
{
	ofCoreEvents coreEvents;
	shared_ptr<ofBaseRenderer> currentRenderer;
	
public:
	
	static void loop(){};
	static bool doesLoop(){ return false; }
	static bool allowsMultiWindow(){ return true; }
	static bool needsPolling(){ return true; }
	static void pollEvents(){  }
	
	virtual void setup(const ofWindowSettings & settings){}
	virtual void update(){}
	virtual void draw(){}
	virtual ofCoreEvents & events(){ return coreEvents; };
	virtual shared_ptr<ofBaseRenderer> & renderer(){ return currentRenderer; };
	
	ofxCocoaGLView *view;

	ofxCocoaGLViewWindowProxy(ofxCocoaGLView *view_)
	{
        view = view_;
        currentRenderer = shared_ptr<ofBaseRenderer>(new ofGLRenderer(this));
        
        ofGLWindowSettings settings;
        settings.glVersionMajor = 2;
        settings.glVersionMinor = 1;
        
        // to-do!
        if(currentRenderer->getType()==ofGLProgrammableRenderer::TYPE){
            static_cast<ofGLProgrammableRenderer*>(currentRenderer.get())->setup(settings.glVersionMajor,settings.glVersionMinor);
        }else{
            static_cast<ofGLRenderer*>(currentRenderer.get())->setup();
        }
        
        currentRenderer->setOrientation(OF_ORIENTATION_DEFAULT, false);
	}

	int getWidth()
	{
		return view.bounds.size.width;
	}

	int getHeight()
	{
		return view.bounds.size.height;
	}

	ofPoint getWindowSize()
	{
		NSSize size = view.bounds.size;
		return ofPoint(size.width, size.height);
	}

	int getFrameNum()
	{
		return view->frameCount;
	}

	float getFrameRate()
	{
		return view->frameRate;
	}

	double getLastFrameTime()
	{
		return view->lastFrameTime;
	}

	void setFrameRate(float targetRate)
	{
		[view setFrameRate:targetRate];
	}

	void setFullscreen(bool fullscreen)
	{
		[view setFullscreen:fullscreen];
	}

	void toggleFullscreen()
	{
		[view toggleFullscreen];
	}

	void hideCursor()
	{
		[NSCursor hide];
	}

	void showCursor()
	{
		[NSCursor unhide];
	}

	void setWindowPosition(int x, int y)
	{
		OFXCOCOAGLVIEW_IGNORED;
	}

	void setWindowShape(int w, int h)
	{
		OFXCOCOAGLVIEW_IGNORED;
	}

	void setWindowTitle(string title)
	{
		OFXCOCOAGLVIEW_IGNORED;
	}
};

static ofPtr<ofxCocoaGLViewWindowProxy> window_proxy;

static void setupWindowProxy(ofxCocoaGLView *view)
{
	if (window_proxy) return;
	window_proxy = ofPtr<ofxCocoaGLViewWindowProxy>(new ofxCocoaGLViewWindowProxy(view));
	ofSetupOpenGL(window_proxy, view.bounds.size.width, view.bounds.size.height, OF_WINDOW);
}

static void makeCurrentView(ofxCocoaGLView *view)
{
	if (window_proxy)
		window_proxy->view = view;
}

class ScopedAutoReleasePool
{
public:
	
	ScopedAutoReleasePool()
	{
		pool = [[NSAutoreleasePool alloc] init];
	}
	
	~ScopedAutoReleasePool()
	{
		[pool release];
	}
	
private:
	
	NSAutoreleasePool *pool;
	
	ScopedAutoReleasePool(const ScopedAutoReleasePool&);
	ScopedAutoReleasePool& operator=(const ScopedAutoReleasePool&);
};

static NSOpenGLContext *_context = nil;

@interface ofxCocoaGLView ()
- (void)initGL;
- (void)drawView;
- (void)dispose;
- (BOOL)isVisible;
@end

@implementation ofxCocoaGLView

@synthesize mouseX, mouseY;
@synthesize width, height;

+ (NSOpenGLContext*)sharedContext
{
	return _context;
}

+ (void)lockSharedContext
{
	[_context makeCurrentContext];
	CGLContextObj cglContext = (CGLContextObj)[_context CGLContextObj];
	CGLLockContext(cglContext);
}

+ (void)unlockSharedContext
{
	CGLContextObj cglContext = (CGLContextObj)[_context CGLContextObj];
	CGLUnlockContext(cglContext);
}

- (id)initWithCoder:(NSCoder *)aDecoder
{
	self = [super initWithCoder:aDecoder];

	if (self)
	{
		ScopedAutoReleasePool pool;
		
		initialised = NO;
		enableSetupScreen = YES;
		frameCount = 0;

		translucent = NO;
		useDisplayLink = NO;

		targetFrameRate = 60;
		frameRate = 0;

		lastUpdateTime = 0;
		lastFrameTime = 0;

		mouseX = mouseY = 0;

		globalMonitorHandler = nil;
		localMonitorHandler = nil;

		displayLink = NULL;
		updateTimer = nil;
        
        pixelScreenCoordScale = 1.0;
        
		if (_context == nil)
		{
			_context = [self openGLContext];
		}
		else
		{
			self.openGLContext = [[[NSOpenGLContext alloc] initWithFormat:self.pixelFormat shareContext:_context] autorelease];
		}

		{
			GLint double_buffer = 0;
			[self.pixelFormat getValues:&double_buffer forAttribute:NSOpenGLPFADoubleBuffer forVirtualScreen:0];

			if (double_buffer == 0)
				ofLogWarning("ofxCocoaGLView") << "double buffer is disabled";
		}

        {
            //BOOL retina = [self wantsBestResolutionOpenGLSurface];
            
            NSRect unscaledBounds = [self bounds];
            NSRect scaledBounds = [self convertRectToBacking:[self bounds]];
            
            pixelScreenCoordScale = scaledBounds.size.width / unscaledBounds.size.width;
        }
        
		{
			localMonitorHandler = [NSEvent addLocalMonitorForEventsMatchingMask:NSMouseMovedMask handler:^(NSEvent *e) {
				if ([self isVisible])
					[self _mouseMoved:e];
				return e;
			}];

			globalMonitorHandler = [NSEvent addGlobalMonitorForEventsMatchingMask:NSMouseMovedMask handler:^(NSEvent *e) {
				if ([self isVisible])
					[self _mouseMoved:e];
			}];

			NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
			
			// setup terminate notification
			[nc addObserver:self
				   selector:@selector(applicationWillTerminate:)
					   name:NSApplicationWillTerminateNotification
					 object:nil];
			
			[nc addObserver:self
				   selector:@selector(applicationDidFinishLaunching:)
					   name:NSApplicationDidFinishLaunchingNotification
					 object:nil];
			
			trackingRectTag = NULL;
			
			// TODO: NSWindowDidChangeScreenNotification
		}
		
		[self.window setFrameUsingName:[self className] force:YES];
		[self setFrameRate:60];
	}
	
	return self;
}

- (void)dispose
{
	ScopedAutoReleasePool pool;
	
	if (![self isInFullScreenMode])
		[self.window saveFrameUsingName:[self className]];
	
	[self exit];

	if (updateTimer)
	{
		[updateTimer invalidate];
		updateTimer = nil;
	}

	if (displayLink)
	{
		CVDisplayLinkStop(displayLink);
		CVDisplayLinkRelease(displayLink);
		displayLink = NULL;
	}

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc removeObserver:self];

	if (localMonitorHandler)
	{
		[NSEvent removeMonitor:localMonitorHandler];
		localMonitorHandler = nil;
	}

	if (globalMonitorHandler)
	{
		[NSEvent removeMonitor:globalMonitorHandler];
		globalMonitorHandler = nil;
	}

	if (trackingRectTag)
	{
		[self removeTrackingRect:trackingRectTag];
		trackingRectTag = NULL;
	}
}

- (void)applicationWillTerminate:(id)sender
{
	[self dispose];
}

- (void)applicationDidFinishLaunching:(id)sender
{
	ScopedAutoReleasePool pool;
	
	BEGIN_OPENGL();
	
	[self setup];
	ofEvents().notifySetup();

	END_OPENGL();
	
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc removeObserver:self name:NSApplicationDidFinishLaunchingNotification object:nil];
	
	initialised = YES;
}

- (void)dealloc
{
	[self dispose];
	[super dealloc];
}

- (void)setFrameRate:(float)v
{
	targetFrameRate = v;
	frameRate = targetFrameRate;

	[self enableDisplayLink:useDisplayLink];
}

- (void)setFullscreenTo:(NSScreen*)screen
{
	if ([self isInFullScreenMode]) return;
	
	NSMutableDictionary *opts = [NSMutableDictionary dictionary];
	
	// auto hide menubar
	[opts setObject:[NSNumber numberWithInt:NSApplicationPresentationHideDock | NSApplicationPresentationAutoHideMenuBar] forKey:NSFullScreenModeApplicationPresentationOptions];
	
	// for all screen
	[opts setObject:[NSNumber numberWithBool:NO] forKey:NSFullScreenModeAllScreens];

	[self enterFullScreenMode:screen withOptions:opts];
}

- (void)exitFullscreen
{
	if (![self isInFullScreenMode]) return;
	
	[self exitFullScreenModeWithOptions:nil];
	[self.window makeFirstResponder:self];
}

- (void)setFullscreen:(BOOL)v
{
	if (v)
	{
		NSPoint center;
		NSRect rect = [self.window frame];

		center.x = rect.origin.x + rect.size.width / 2;
		center.y = rect.origin.y + rect.size.height / 2;

		NSEnumerator *screenEnum = [[NSScreen screens] objectEnumerator];
		NSScreen *screen;
		while (screen = [screenEnum nextObject])
		{
			if (NSPointInRect(center, [screen frame]))
			{
				[self setFullscreenTo:screen];
				break;
			}
		}
	}
	else
	{
		[self exitFullscreen];
	}
}

- (void)toggleFullscreen
{
	[self setFullscreen:![self isInFullScreenMode]];
}

- (void)enableDisplayLink:(BOOL)v
{
	useDisplayLink = v;

	if (displayLink)
	{
		CVDisplayLinkStop(displayLink);
		CVDisplayLinkRelease(displayLink);
		displayLink = NULL;
	}

	if (updateTimer)
	{
		[updateTimer invalidate];
		updateTimer = nil;
	}

	if (v)
	{
		CGLContextObj cglContext = (CGLContextObj)[[self openGLContext] CGLContextObj];
		CGLPixelFormatObj cglPixelFormat = (CGLPixelFormatObj)[[self pixelFormat] CGLPixelFormatObj];

		CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
		CVDisplayLinkSetOutputCallback(displayLink, &DisplayLinkCallback, self);

		CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);

		CVDisplayLinkStart(displayLink);
	}
	else
	{
		float interval = 1. / targetFrameRate;
		updateTimer = [NSTimer timerWithTimeInterval:interval target:self selector:@selector(drawView) userInfo:nil repeats:YES];
		[[NSRunLoop mainRunLoop] addTimer:updateTimer forMode:NSRunLoopCommonModes];
	}
}

- (void)prepareOpenGL
{
	ScopedAutoReleasePool pool;
	
	[super prepareOpenGL];
	[self initGL];
	[self enableDisplayLink:NO];
}

- (void)enableWindowEvents:(BOOL)v
{
	if (v)
	{
		[[self window] makeFirstResponder:self];
	}
	else
	{
		[[self window] makeFirstResponder:nil];
	}
}

- (void)initGL
{
	[self enableWindowEvents:YES];

	// init mouse pos
    NSPoint mouse = [NSEvent mouseLocation];
	NSPoint p = [self.window convertRectFromScreen:NSMakeRect(mouse.x, mouse.y, 1.,1.)].origin;
	NSPoint m = [self convertPoint:p fromView:nil];
	mouseX = m.x;

	BEGIN_OPENGL();

	GLint swapInt = 1;
	[[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];

	GLenum err = glewInit();
	if (GLEW_OK != err)
	{
		NSLog(@"GLEW init error... bailing");
		exit(1);
	}

	setupWindowProxy(self);

	END_OPENGL();
}

- (CVReturn)getFrameForTime:(const CVTimeStamp*)outputTime
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	[self drawView];

	[pool release];
	return kCVReturnSuccess;
}

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,
									  const CVTimeStamp* now,
									  const CVTimeStamp* outputTime,
									  CVOptionFlags flagsIn,
									  CVOptionFlags* flagsOut,
									  void* displayLinkContext)
{
	CVReturn result = [(ofxCocoaGLView*)displayLinkContext getFrameForTime:outputTime];
	return result;
}

- (void)drawView
{
	if (!initialised) return;
		
	if ([self isVisible])
	{
		ScopedAutoReleasePool pool;
		
		BEGIN_OPENGL();
		
		makeCurrentView(self);

		{
			float t = ofGetElapsedTimef();
			lastFrameTime = t - lastUpdateTime;
			float d = 1. / lastFrameTime;

			frameRate += (d - frameRate) * 0.1;

			lastUpdateTime = t;
		}

		[self beginWindowEvent];
		
		glPushAttrib(GL_ALL_ATTRIB_BITS);
		glPushMatrix();
		ofPushStyle();
		
		[self update];
		ofEvents().notifyUpdate();
		
		NSRect r = self.bounds;
		ofViewport(0, 0, r.size.width, r.size.height);

		bool clearAuto = ofGetBackgroundAuto();

		if (clearAuto || frameCount < 3)
		{
			const ofFloatColor &bgColor = ofGetBackgroundColor();
			glClearColor(bgColor[0], bgColor[1], bgColor[2], bgColor[3]);
			glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
		}

		if (enableSetupScreen) ofSetupScreen();

		[self draw];
		ofEvents().notifyDraw();
		
		ofPopStyle();
		glPopMatrix();
		glPopAttrib();
		
		[self endWindowEvent];
		
		glFlush();
		[[self openGLContext] flushBuffer];

		END_OPENGL();
	}

	frameCount++;
}

- (void)reshape
{
	ScopedAutoReleasePool pool;
	
	BEGIN_OPENGL();
	
	[self beginWindowEvent];

	makeCurrentView(self);

	[[self openGLContext] update];

	NSRect r = self.bounds;

	width = r.size.width;
	height = r.size.height;

	[self windowResized:r.size];
    if ( ofGetWindowPtr() != nullptr )
        ofEvents().notifyWindowResized(width, height);

	if (trackingRectTag)
	{
		[self removeTrackingRect:trackingRectTag];
		trackingRectTag = NULL;
	}

	trackingRectTag = [self addTrackingRect:[self bounds] owner:self userData:NULL assumeInside:NO];

	[self endWindowEvent];
	
	[self drawView];
	
	END_OPENGL();
}

#pragma mark events

- (NSPoint)getCurrentMousePos
{
    NSPoint mouse = [NSEvent mouseLocation];
    NSPoint p = [self.window convertRectFromScreen:NSMakeRect(mouse.x, mouse.y, 1.,1.)].origin;
	p = [self convertPoint:p fromView:nil];

	mouseX = p.x;
	mouseY = p.y;

	return p;
}

static int conv_button_number(int n)
{
	static int table[] = {0, 2, 1};
	return table[n];
}

- (void)mouseDown:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mousePressed:p button:b];
	ofEvents().notifyMousePressed(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)mouseDragged:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];
	
	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseDragged:p button:b];
	ofEvents().notifyMouseDragged(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)mouseUp:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseReleased:p button:b];
	ofEvents().notifyMouseReleased(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)_mouseMoved:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];
	
	[self beginWindowEvent];
	
	makeCurrentView(self);

	[self mouseMoved:p];
	ofEvents().notifyMouseMoved(p.x, p.y);
	
	[self endWindowEvent];
}

- (void)rightMouseDown:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mousePressed:p button:b];
	ofEvents().notifyMousePressed(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)rightMouseDragged:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseDragged:p button:b];
	ofEvents().notifyMouseDragged(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)rightMouseUp:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseReleased:p button:b];
	ofEvents().notifyMouseReleased(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)otherMouseDown:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mousePressed:p button:b];
	ofEvents().notifyMousePressed(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)otherMouseDragged:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseDragged:p button:b];
	ofEvents().notifyMouseDragged(p.x, p.y, b);
	
	[self endWindowEvent];
}

- (void)otherMouseUp:(NSEvent *)theEvent
{
	NSPoint p = [self getCurrentMousePos];

	[self beginWindowEvent];
	
	makeCurrentView(self);

	int b = conv_button_number([theEvent buttonNumber]);
	[self mouseReleased:p button:b];
	ofEvents().notifyMouseReleased(p.x, p.y, b);
	
	[self endWindowEvent];
}

#define KEY_CASE(CODE, KEY) case CODE: key = KEY; break;

- (void)keyDown:(NSEvent *)theEvent
{
	const char *c = [[theEvent charactersIgnoringModifiers] UTF8String];
	int key = c[0];
	
	switch ([theEvent keyCode]) {
		KEY_CASE(122, OF_KEY_F1);
		KEY_CASE(120, OF_KEY_F2);
		KEY_CASE(99, OF_KEY_F3);
		KEY_CASE(118, OF_KEY_F4);
		KEY_CASE(96, OF_KEY_F5);
		KEY_CASE(97, OF_KEY_F6);
		KEY_CASE(98, OF_KEY_F7);
		KEY_CASE(100, OF_KEY_F8);
		KEY_CASE(101, OF_KEY_F9);
		KEY_CASE(109, OF_KEY_F10);
		KEY_CASE(103, OF_KEY_F11);
		KEY_CASE(111, OF_KEY_F12);
		KEY_CASE(51, OF_KEY_DEL);
		KEY_CASE(116, OF_KEY_HOME);
		KEY_CASE(121, OF_KEY_END);
		KEY_CASE(115, OF_KEY_PAGE_UP);
		KEY_CASE(119, OF_KEY_PAGE_DOWN);
		KEY_CASE(123, OF_KEY_LEFT);
		KEY_CASE(124, OF_KEY_RIGHT);
		KEY_CASE(125, OF_KEY_DOWN);
		KEY_CASE(126, OF_KEY_UP);
		default:
			break;
	}
	
	[self beginWindowEvent];
	
	makeCurrentView(self);

	if (key == OF_KEY_ESC)
	{
		[[NSApplication sharedApplication] terminate:self];
		[NSApp terminate:self];
	}

	[self keyPressed:key];
	ofEvents().notifyKeyPressed(key);
	
	[self endWindowEvent];
}

- (void)keyUp:(NSEvent *)theEvent
{
	const char *c = [[theEvent charactersIgnoringModifiers] UTF8String];
	int key = c[0];
	
	switch ([theEvent keyCode]) {
		KEY_CASE(122, OF_KEY_F1);
		KEY_CASE(120, OF_KEY_F2);
		KEY_CASE(99, OF_KEY_F3);
		KEY_CASE(118, OF_KEY_F4);
		KEY_CASE(96, OF_KEY_F5);
		KEY_CASE(97, OF_KEY_F6);
		KEY_CASE(98, OF_KEY_F7);
		KEY_CASE(100, OF_KEY_F8);
		KEY_CASE(101, OF_KEY_F9);
		KEY_CASE(109, OF_KEY_F10);
		KEY_CASE(103, OF_KEY_F11);
		KEY_CASE(111, OF_KEY_F12);
		KEY_CASE(51, OF_KEY_DEL);
		KEY_CASE(116, OF_KEY_HOME);
		KEY_CASE(121, OF_KEY_END);
		KEY_CASE(115, OF_KEY_PAGE_UP);
		KEY_CASE(119, OF_KEY_PAGE_DOWN);
		KEY_CASE(123, OF_KEY_LEFT);
		KEY_CASE(124, OF_KEY_RIGHT);
		KEY_CASE(125, OF_KEY_DOWN);
		KEY_CASE(126, OF_KEY_UP);
		default:
			break;
	}

	[self beginWindowEvent];
	
	makeCurrentView(self);

	[self keyReleased:key];
	ofEvents().notifyKeyReleased(key);
	
	[self endWindowEvent];
}

- (void)mouseEntered:(NSEvent *)event
{
	[self beginWindowEvent];
	
	[self mouseEntered];
	
	[self endWindowEvent];
}

- (void)mouseExited:(NSEvent *)event
{
	[self beginWindowEvent];
	
	[self mouseExited];
	
	[self endWindowEvent];
}

- (void)beginWindowEvent {}
- (void)endWindowEvent {}

#pragma mark oF like API

- (void)setup {}
- (void)update {}
- (void)draw {}
- (void)exit {}

- (void)keyPressed:(int)key {}
- (void)keyReleased:(int)key {}
- (void)mouseMoved:(NSPoint)p {}
- (void)mouseDragged:(NSPoint)p button:(int)button {}
- (void)mousePressed:(NSPoint)p button:(int)button {}
- (void)mouseReleased:(NSPoint)p button:(int)button {}
- (void)windowResized:(NSSize)size {}

- (void)mouseEntered {}
- (void)mouseExited {}

//

- (void)setTranslucent:(BOOL)v
{
	translucent = v;

	GLint opt = translucent ? 0 : 1;
	[[self openGLContext] setValues:&opt forParameter:NSOpenGLCPSurfaceOpacity];
}

- (BOOL)isTranslucent
{
	return translucent;
}

- (BOOL)isOpaque
{
	return !translucent;
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (BOOL)becomeFirstResponder
{
	return YES;
}

- (BOOL)resignFirstResponder
{
	return YES;
}

//

- (void)_surfaceNeedsUpdate:(NSNotification*)notification
{
	if (!initialised)
	{
		[super update];
		return;
	}

	[self update];
}

- (BOOL)isVisible
{
	return self.window && [self.window isVisible];
}

- (void)setKeepAspect:(float)aspect_
{
	if (!self.window) return;
	
	aspect = aspect_;
	[self.window setDelegate:self];
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize
{
	NSRect r;
	
	r = NSMakeRect([sender frame].origin.x,
				   [sender frame].origin.y,
				   frameSize.width,
				   frameSize.height);
	
	r = [sender contentRectForFrameRect:r];
	r.size.height = r.size.width * aspect;
	r = [sender frameRectForContentRect:r];
	
	return r.size;
}


- (int) getPixelScreenCoordScale
{
    return pixelScreenCoordScale;
}

@end
