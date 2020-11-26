//
//  HLSPrefetcher.m
//  CocoaAsyncSocket
//
//  Created by BlueDancer on 2020/6/11.
//

#import "HLSPrefetcher.h"
#import "MCSLogger.h"
#import "MCSAssetManager.h"
#import "NSURLRequest+MCS.h"  
#import "HLSAsset.h"
#import "HLSContentTSReader.h"
#import "HLSContentIndexReader.h"
#import "MCSQueue.h"

@interface HLSPrefetcher ()<MCSAssetReaderDelegate>
@property (nonatomic) BOOL isCalledPrepare;
@property (nonatomic) BOOL isClosed;
@property (nonatomic) BOOL isDone;
 
@property (nonatomic, strong, nullable) id<MCSAssetReader> reader;
@property (nonatomic) NSUInteger loadedLength;
@property (nonatomic) float progress;

@property (nonatomic, weak, nullable) HLSAsset *asset;
@property (nonatomic) NSUInteger fragmentIndex;

@property (nonatomic, strong) NSURL *URL;
@property (nonatomic) NSUInteger preloadSize;
@property (nonatomic) NSUInteger numberOfPreloadFiles;
@end

@implementation HLSPrefetcher
@synthesize delegate = _delegate;
@synthesize delegateQueue = _delegateQueue;
- (instancetype)initWithURL:(NSURL *)URL preloadSize:(NSUInteger)bytes delegate:(nullable id<MCSPrefetcherDelegate>)delegate delegateQueue:(nonnull dispatch_queue_t)delegateQueue {
    self = [super init];
    if ( self ) {
        _URL = URL;
        _preloadSize = bytes;
        _delegate = delegate;
        _delegateQueue = delegateQueue;
        _fragmentIndex = NSNotFound;
    }
    return self;
}

- (instancetype)initWithURL:(NSURL *)URL numberOfPreloadFiles:(NSUInteger)num delegate:(nullable id<MCSPrefetcherDelegate>)delegate delegateQueue:(dispatch_queue_t)delegateQueue {
    self = [super init];
    if ( self ) {
        _URL = URL;
        _numberOfPreloadFiles = num;
        _delegate = delegate;
        _delegateQueue = delegateQueue;
        _fragmentIndex = NSNotFound;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"%@:<%p> { preloadSize: %lu, numberOfPreloadFiles: %lu };\n", NSStringFromClass(self.class), self, (unsigned long)_preloadSize, (unsigned long)_numberOfPreloadFiles];
}

- (void)dealloc {
    MCSPrefetcherDebugLog(@"%@: <%p>.dealloc;\n", NSStringFromClass(self.class), self);
}

- (void)prepare {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        if ( _isClosed || _isCalledPrepare )
            return;

        MCSPrefetcherDebugLog(@"%@: <%p>.prepare { preloadSize: %lu, numberOfPreloadFiles: %lu };\n", NSStringFromClass(self.class), self, (unsigned long)_preloadSize, (unsigned long)_numberOfPreloadFiles);
        
        _isCalledPrepare = YES;
        _asset = [MCSAssetManager.shared assetWithURL:_URL];

        NSURLRequest *request = [NSURLRequest.alloc initWithURL:_URL];
        _reader = [MCSAssetManager.shared readerWithRequest:request];
        _reader.delegate = self;
        [_reader prepare];
    });
}

- (void)close {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        [self _close];
    });
}

- (float)progress {
    __block float progress = 0;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        progress = _progress;
    });
    return progress;
}

- (BOOL)isClosed {
    __block BOOL isClosed = NO;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        isClosed = _isClosed;
    });
    return isClosed;
}

- (BOOL)isDone {
    __block BOOL isDone = NO;
    dispatch_sync(dispatch_get_global_queue(0, 0), ^{
        isDone = _isDone;
    });
    return isDone;
}

#pragma mark - MCSAssetReaderDelegate

- (void)reader:(id<MCSAssetReader>)reader prepareDidFinish:(id<MCSResponse>)response {
    /* nothing */
}

- (void)reader:(id<MCSAssetReader>)reader hasAvailableDataWithLength:(NSUInteger)length {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        if ( _isClosed )
            return;
        
        if ( [reader seekToOffset:reader.offset + length] ) {
            if ( _fragmentIndex != NSNotFound )
                _loadedLength += length;
            
            CGFloat progress = 0;
            if ( _preloadSize != 0 ) {
                NSUInteger size = _preloadSize < reader.response.totalLength ? reader.response.totalLength : _preloadSize;
                progress = _loadedLength * 1.0 / size;
            }
            else {
                CGFloat curr = reader.offset / reader.response.range.length;
                progress = (_fragmentIndex + curr) / _numberOfPreloadFiles;
            }
            
            if ( progress >= 1 ) progress = 1;
            _progress = progress;
            
            MCSPrefetcherDebugLog(@"%@: <%p>.preload { progress: %f };\n", NSStringFromClass(self.class), self, _progress);
            
            if ( _delegate != nil ) {
                dispatch_async(_delegateQueue, ^{
                    [self.delegate prefetcher:self progressDidChange:progress];
                });
            }
            
            if ( reader.isReadingEndOfData ) {
                BOOL isLastFragment = _fragmentIndex == _asset.parser.TsCount - 1;
                BOOL isFinished = progress >= 1 || isLastFragment;
                if ( !isFinished ) {
                    [self _prepareNextFragment];
                    return;
                }
                
                [self _didCompleteWithError:nil];
            }
        }
    });
}
  
- (void)reader:(id<MCSAssetReader>)reader anErrorOccurred:(NSError *)error {
    dispatch_barrier_sync(dispatch_get_global_queue(0, 0), ^{
        [self _didCompleteWithError:error];
    });
}

#pragma mark -

- (void)_prepareNextFragment {
    _fragmentIndex = (_fragmentIndex == NSNotFound) ? 0 : (_fragmentIndex + 1);
    
    NSString *TsURI = [_asset.parser URIAtIndex:_fragmentIndex];
    NSURL *proxyURL = [MCSURLRecognizer.shared proxyURLWithTsURI:TsURI];
    NSURLRequest *request = [NSURLRequest requestWithURL:proxyURL];
    _reader = [MCSAssetManager.shared readerWithRequest:request];
    _reader.networkTaskPriority = 0;
    _reader.delegate = self;
    [_reader prepare];
    
    MCSPrefetcherDebugLog(@"%@: <%p>.prepareFragment { index:%lu, request: %@ };\n", NSStringFromClass(self.class), self, (unsigned long)_fragmentIndex, request);
}

- (void)_didCompleteWithError:(nullable NSError *)error {
    if ( _isClosed )
        return;
    
    _isDone = (error == nil);
    
#ifdef DEBUG
    if ( _isDone )
        MCSPrefetcherDebugLog(@"%@: <%p>.done;\n", NSStringFromClass(self.class), self);
    else
        MCSPrefetcherErrorLog(@"%@:  <%p>.error { error: %@ };\n", NSStringFromClass(self.class), self, error);
#endif
    
    [self _close];
    
    if ( _delegate != nil ) {
        dispatch_async(_delegateQueue, ^{
            [self.delegate prefetcher:self didCompleteWithError:error];
        });
    }
}

- (void)_close {
    if ( _isClosed )
        return;
    
    [_reader close];
    
    _isClosed = YES;

    MCSPrefetcherDebugLog(@"%@: <%p>.close;\n", NSStringFromClass(self.class), self);
}
@end
