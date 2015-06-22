#import <Cocoa/Cocoa.h>

int main(int argc, char *argv[])
{
	@try {
		return NSApplicationMain(argc, (const char **)argv);
	}
	@catch (NSException *exception) {
		NSLog(@"%@", exception);
	}
}
