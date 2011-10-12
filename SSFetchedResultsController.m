//
//  SSFetchedResultsController.m
//  SSFetchedResultsController
//
//  Created by Sam Soffes on 10/12/11.
//  Copyright (c) 2011 Sam Soffes. All rights reserved.
//

#import "SSFetchedResultsController.h"

#ifndef DEBUG
#define DEBUG NO
#endif

// The NSFetchedResultsController class has one major flaw.
// It will incorrectly flag moved objects as simple updates in the face or inserts or deletions.
// 
// Depending on the context of the changes, this can cause a crash,
// or simply cause the improper table cell to be updated.
// The latter problem leaves another table cell with a stale value, which may be critical to the application.
// 
// The problem occurs when an inserted/deleted section/object causes a moved object to
// end up at the same index path as where it was before.
// 
// This is a bit difficult to explain without a few examples.
// For the following example, we will designate index paths with [<section>,<row>].
// 
// Imagine a simple table with names, sorted alphabetically.
// The table currently has two rows:
// 
// [0,0] "Robbie Hanson"
// [0,1] "Z"
// 
// Now imagine that "Adam West" is added, and at the same time, "Z" is changed to "Benjamin Zacharias".
// So we should end up with this:
// 
// [0,0] "Adam West"
// [0,1] "Benjamin Zacharias"
// [0,2] "Robbie Hanson"
// 
// But notice that the index path of "Z" didn't actually change, due to the insert.
// So the NSFetchedResultsController reports an insert at [0,0] and a simple update at [0,1].
// Passing this information to a table actually causes it to insert at [0,0] and update [0,2].
// Which actually creates a completely incorrect table:
// 
// [0,0] "Adam West"
// [0,1] "Robbie Hanson" <- Wrong!
// [0,2] "Robbie Hanson" <- Updated needlessly.
// 
// This is one simple example of the problems caused by the NSFetchedResultsController.
// There are other times when this bug actually causes an application crash.
// See the giant comment blocks below for several more examples.

@interface SSSectionChange : NSObject

@property (nonatomic, retain) id <NSFetchedResultsSectionInfo> sectionInfo;
@property (nonatomic, assign) NSUInteger sectionIndex;
@property (nonatomic, assign) NSFetchedResultsChangeType changeType;

- (id)initWithSectionInfo:(id <NSFetchedResultsSectionInfo>)sectionInfo
                    index:(NSUInteger)sectionIndex
               changeType:(NSFetchedResultsChangeType)changeType;
@end

@interface SSObjectChange : NSObject

@property (nonatomic, retain) id object;
@property (nonatomic, retain) NSIndexPath *indexPath;
@property (nonatomic, assign) NSFetchedResultsChangeType changeType;
@property (nonatomic, retain) NSIndexPath *changedIndexPath;

- (id)initWithObject:(id)object
           indexPath:(NSIndexPath *)indexPath
          changeType:(NSFetchedResultsChangeType)changeType
        newIndexPath:(NSIndexPath *)newIndexPath;
@end

@interface SSFetchedResultsController (PrivateAPI)

- (NSDictionary *)createIndexDictionaryFromArray:(NSArray *)array;

@end

#pragma mark -

@implementation SSFetchedResultsController {
	NSMutableArray *_insertedSections;
	NSMutableArray *_deletedSections;
	
	NSMutableArray *_insertedObjects;
	NSMutableArray *_deletedObjects;
	NSMutableArray *_updatedObjects;
	NSMutableArray *_movedObjects;
}

@synthesize safeDelegate = _safeDelegate;

- (id)initWithFetchRequest:(NSFetchRequest *)fetchRequest
      managedObjectContext:(NSManagedObjectContext *)context
        sectionNameKeyPath:(NSString *)sectionNameKeyPath
                 cacheName:(NSString *)name
{
	self = [super initWithFetchRequest:fetchRequest
	              managedObjectContext:context
	               	sectionNameKeyPath:sectionNameKeyPath
	                         cacheName:name];
	if(self)
	{
		super.delegate = self;
		
		_insertedSections = [[NSMutableArray alloc] init];
		_deletedSections  = [[NSMutableArray alloc] init];
		
		_insertedObjects  = [[NSMutableArray alloc] init];
		_deletedObjects   = [[NSMutableArray alloc] init];
		_updatedObjects   = [[NSMutableArray alloc] init];
		_movedObjects     = [[NSMutableArray alloc] init];
	}
	return self;
}


- (void)dealloc
{
	[_insertedSections release];
	[_deletedSections release];
	
	[_insertedObjects release];
	[_deletedObjects release];
	[_updatedObjects release];
	[_movedObjects release];
	
	[super dealloc];
}


#pragma mark - Logic

/**
 * Checks to see if there are unsafe changes in the current change set.
**/
- (BOOL)hasUnsafeChanges
{
	NSUInteger numSectionChanges = [_insertedSections count] + [_deletedSections count];
	
	if (numSectionChanges > 1)
	{
		// Multiple section changes can still cause crashes in UITableView.
		// This appears to be a bug in UITableView.
		
		return YES;
	}
	
	return NO;
}


/**
 * Helper method for hasPossibleUpdateBug.
 * Please see that method for documenation.
**/
- (void)addIndexPath:(NSIndexPath *)indexPath toDictionary:(NSMutableDictionary *)dictionary
{
	NSNumber *sectionNumber = [NSNumber numberWithUnsignedInteger:(NSUInteger)indexPath.section];
	
	NSMutableIndexSet *indexSet = [dictionary objectForKey:sectionNumber];
	if (indexSet == nil)
	{
		indexSet = [[[NSMutableIndexSet alloc] init] autorelease];
		
		[dictionary setObject:indexSet forKey:sectionNumber];
	}
	
	if (DEBUG)
	{
		NSLog(@"Adding index(%i) to section(%@)", indexPath.row, sectionNumber);
	}
	
	[indexSet addIndex:(NSUInteger)indexPath.row];
}


/**
 * Checks to see if there are any moved objects that might have been improperly tagged as updated objects.
**/
- (void)fixUpdateBugs
{
	if ([_updatedObjects count] == 0) return;
	
	// In order to test if a move could have been improperly flagged as an update,
	// we have to test to see if there are any insertions, deletions or moves that could
	// have possibly affected the update.
	
	NSUInteger numInsertedSections = [_insertedSections count];
	NSUInteger numDeletedSections  = [_deletedSections  count];
	
	NSUInteger numInsertedObjects = [_insertedObjects count] + [_movedObjects count];
	NSUInteger numDeletedObjects  = [_deletedObjects  count] + [_movedObjects count];
	
	NSUInteger numChangedSections = numInsertedSections + numDeletedSections;
	NSUInteger numChangedObjects = numInsertedObjects + numDeletedObjects;
	
	if (numChangedSections > 0 || numChangedObjects > 0)
	{
		// First we create index sets for the inserted and deleted sections.
		// This will allow us to see if a section change could have created a problem.
		
		NSMutableIndexSet *sectionInsertSet = [[[NSMutableIndexSet alloc] init] autorelease];
		NSMutableIndexSet *sectionDeleteSet = [[[NSMutableIndexSet alloc] init] autorelease];
		
		for (SSSectionChange *sectionChange in _insertedSections)
		{
			[sectionInsertSet addIndex:sectionChange.sectionIndex];
		}
		for (SSSectionChange *sectionChange in _deletedSections)
		{
			[sectionDeleteSet addIndex:sectionChange.sectionIndex];
		}
		
		// Next we create dictionaries of index sets for the object changes.
		// 
		// The keys for the dictionary will be each indexPath.section from the object changes.
		// And the corresponding values are an NSIndexSet with all the indexPath.row values from that section.
		// 
		// For example:
		// 
		// Insertions: [2,0], [1,2]
		// Deletions : [0,4]
		// Moves     : [2,3] -> [1,5]
		// 
		// InsertDict = {
		//   1 = {2,5},
		//   2 = {0}
		// }
		// 
		// DeleteDict = {
		//   0 = {4},
		//   2 = {3}
		// }
		// 
		// From these dictionaries we can quickly test to see if a move could
		// have been improperly flagged as an update.
		// 
		// Update at [4,2] -> Not affected
		// Update at [0,1] -> Not affected
		// Update at [2,1] -> Possibly affected (1)
		// Update at [0,5] -> Possibly affected (2)
		// Update at [2,4] -> Possibly affected (3)
		// 
		// How could they have been affected?
		// 
		// 1) The "updated" object was originally at [2,1],
		//    and then its sort value changed, prompting it to move to [2,0].
		//    But at the same time an object is inserted at [2,0].
		//    The final index path is still [2,1] so NSFRC reports it as an update.
		// 
		// 2) The "updated" object was originally at [0,5],
		//    and then its sort value changed, prompting it to move to [0,6].
		//    But at the same time, an object is deleted at [0,4].
		//    The final index path is still [0,5] so NSFRC reports it as an update.
		// 
		// 3) The move is essentially the same as a deletion at [2,3].
		//    So this is similar to the example above.
		
		NSMutableDictionary *objectInsertDict = [NSMutableDictionary dictionaryWithCapacity:numInsertedObjects];
		NSMutableDictionary *objectDeleteDict = [NSMutableDictionary dictionaryWithCapacity:numDeletedObjects];
		
		for (SSObjectChange *objectChange in _insertedObjects)
		{
			[self addIndexPath:objectChange.changedIndexPath toDictionary:objectInsertDict];
		}
		for (SSObjectChange *objectChange in _deletedObjects)
		{
			[self addIndexPath:objectChange.indexPath toDictionary:objectDeleteDict];
		}
		for (SSObjectChange *objectChange in _movedObjects)
		{
			[self addIndexPath:objectChange.indexPath toDictionary:objectDeleteDict];
			[self addIndexPath:objectChange.changedIndexPath toDictionary:objectInsertDict];
		}
		
		for (SSObjectChange *objectChange in _updatedObjects)
		{
			if (DEBUG)
			{
				NSLog(@"Processing %@", objectChange);
			}
			
			if (objectChange.changedIndexPath == nil)
			{
				NSIndexPath *indexPath = objectChange.indexPath;
				
				// Determine if affected by section changes
				
				NSRange range = NSMakeRange(0 /*location*/, (NSUInteger)indexPath.section + 1 /*length*/);
				
				numInsertedSections = [sectionInsertSet countOfIndexesInRange:range];
				numDeletedSections  = [sectionDeleteSet countOfIndexesInRange:range];
				
				// Determine if affected by object changes
				
				NSNumber *sectionNumber = [NSNumber numberWithUnsignedInteger:(NSUInteger)indexPath.section];
				
				range = NSMakeRange(0 /*location*/, (NSUInteger)indexPath.row + 1 /*length*/);
				
				numInsertedObjects = 0;
				numDeletedObjects = 0;
				
				NSIndexSet *insertsInSameSection = [objectInsertDict objectForKey:sectionNumber];
				if (insertsInSameSection)
				{
					numInsertedObjects = [insertsInSameSection countOfIndexesInRange:range];
				}
				
				NSIndexSet *deletesInSameSection = [objectDeleteDict objectForKey:sectionNumber];
				if (deletesInSameSection)
				{
					numDeletedObjects = [deletesInSameSection countOfIndexesInRange:range];
				}
				
				// If the update might actually be a move,
				// then alter the objectChange to reflect the possibility.
				
				if (DEBUG)
				{
					NSLog(@"numInsertedSections: %u", numInsertedSections);
					NSLog(@"numDeletedSections: %u", numDeletedSections);
					
					NSLog(@"numInsertedObjects: %u", numInsertedObjects);
					NSLog(@"numDeletedObjects: %u", numDeletedObjects);
				}
				
				numChangedSections = numInsertedSections + numDeletedSections;
				numChangedObjects = numInsertedObjects + numDeletedObjects;
				
				if (numChangedSections > 0 || numChangedObjects > 0)
				{
					objectChange.changedIndexPath = objectChange.indexPath;
				}
			}
		}
	}
	
	// One more example of a move causing a problem:
	// 
	// [0,0] "Catherine"
	// [0,1] "King"
	// [0,2] "Tuttle"
	// 
	// Now imagine that we make the following changes:
	// 
	// "King" -> "Ben King"
	// "Tuttle" -> "Alex Tuttle"
	// 
	// We should end up with this
	// 
	// [0,0] "Alex Tuttle" <- Moved from [0,2]
	// [0,1] "Ben King"    <- Moved from [0,1]
	// [0,2] "Catherine"
	// 
	// However, because index path for "King" remained the same,
	// the NSFRC incorrectly reports it as an update.
	// 
	// The end result is similar to the example given at the very top of this file.
}


#pragma mark - Processing

- (void)notifyDelegateOfSectionChange:(SSSectionChange *)sectionChange
{
	SEL selector = @selector(controller:didChangeSection:atIndex:forChangeType:);
	
	if ([_safeDelegate respondsToSelector:selector])
	{
		[_safeDelegate controller:self
		        didChangeSection:sectionChange.sectionInfo
		                 atIndex:sectionChange.sectionIndex
		           forChangeType:sectionChange.changeType];
	}
}


- (void)notifyDelegateOfObjectChange:(SSObjectChange *)objectChange
{
	SEL selector = @selector(controller:didChangeObject:atIndexPath:forChangeType:newIndexPath:);
	
	if ([_safeDelegate respondsToSelector:selector])
	{
		[_safeDelegate controller:self
		         didChangeObject:objectChange.object
		             atIndexPath:objectChange.indexPath
		           forChangeType:objectChange.changeType
		            newIndexPath:objectChange.changedIndexPath];
	}
}


- (void)processSectionChanges
{
	for (SSSectionChange *sectionChange in _insertedSections)
	{
		[self notifyDelegateOfSectionChange:sectionChange];
	}
	for (SSSectionChange *sectionChange in _deletedSections)
	{
		[self notifyDelegateOfSectionChange:sectionChange];
	}
}


- (void)processObjectChanges
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	
	// Check for and possibly fix the InsertSection or DeleteSection bug
	
	[self fixUpdateBugs];
	
	// Process object changes
	
	for (SSObjectChange *objectChange in _insertedObjects)
	{
		[self notifyDelegateOfObjectChange:objectChange];
	}
	for (SSObjectChange *objectChange in _deletedObjects)
	{
		[self notifyDelegateOfObjectChange:objectChange];
	}
	for (SSObjectChange *objectChange in _updatedObjects)
	{
		[self notifyDelegateOfObjectChange:objectChange];
	}
	for (SSObjectChange *objectChange in _movedObjects)
	{
		[self notifyDelegateOfObjectChange:objectChange];
	}
	
	[pool release];
}


- (void)processChanges
{
	if (DEBUG)
	{
		NSLog(@"SSFetchedResultsController: processChanges");
		
		for (SSSectionChange *sectionChange in _insertedSections)
		{
			NSLog(@"%@", sectionChange);
		}
		for (SSSectionChange *sectionChange in _deletedSections)
		{
			NSLog(@"%@", sectionChange);
		}
		
		for (SSObjectChange *objectChange in _insertedObjects)
		{
			NSLog(@"%@", objectChange);
		}
		for (SSObjectChange *objectChange in _deletedObjects)
		{
			NSLog(@"%@", objectChange);
		}
		for (SSObjectChange *objectChange in _updatedObjects)
		{
			NSLog(@"%@", objectChange);
		}
		for (SSObjectChange *objectChange in _movedObjects)
		{
			NSLog(@"%@", objectChange);
		}
	}
	
	if ([self hasUnsafeChanges])
	{
		if ([_safeDelegate respondsToSelector:@selector(controllerDidMakeUnsafeChanges:)])
		{
			[_safeDelegate controllerDidMakeUnsafeChanges:self];
		}
	}
	else
	{
		if ([_safeDelegate respondsToSelector:@selector(controllerWillChangeContent:)])
		{
			[_safeDelegate controllerWillChangeContent:self];
		}
		
		[self processSectionChanges];
		[self processObjectChanges];
		
		if ([_safeDelegate respondsToSelector:@selector(controllerDidChangeContent:)])
		{
			[_safeDelegate controllerDidChangeContent:self];
		}
	}
}


#pragma mark - NSFetchedResultsControllerDelegate

- (void)controllerWillChangeContent:(NSFetchedResultsController *)controller
{
	// Nothing to do yet
}


- (void)controller:(NSFetchedResultsController *)controller
  didChangeSection:(id <NSFetchedResultsSectionInfo>)sectionInfo
           atIndex:(NSUInteger)sectionIndex
     forChangeType:(NSFetchedResultsChangeType)changeType
{
	// Queue changes for processing later
	
	SSSectionChange *sectionChange = [[SSSectionChange alloc] initWithSectionInfo:sectionInfo
	                                                                            index:sectionIndex
	                                                                       changeType:changeType];
	NSMutableArray *sectionChanges = nil;
	
	switch (changeType)
	{
		case NSFetchedResultsChangeInsert : sectionChanges = _insertedSections; break;
		case NSFetchedResultsChangeDelete : sectionChanges = _deletedSections;  break;
	}
	
	[sectionChanges addObject:sectionChange];
	[sectionChange release];
}


- (void)controller:(NSFetchedResultsController *)controller
   didChangeObject:(id)anObject
       atIndexPath:(NSIndexPath *)indexPath
     forChangeType:(NSFetchedResultsChangeType)changeType
      newIndexPath:(NSIndexPath *)newIndexPath
{
	// Queue changes for processing later
	
	SSObjectChange *objectChange = [[SSObjectChange alloc] initWithObject:anObject
	                                                                indexPath:indexPath
	                                                               changeType:changeType
	                                                             newIndexPath:newIndexPath];
	NSMutableArray *objectChanges = nil;
	
	switch (changeType)
	{
		case NSFetchedResultsChangeInsert : objectChanges = _insertedObjects; break;
		case NSFetchedResultsChangeDelete : objectChanges = _deletedObjects;  break;
		case NSFetchedResultsChangeUpdate : objectChanges = _updatedObjects;  break;
		case NSFetchedResultsChangeMove   : objectChanges = _movedObjects;    break;
	}
	
	[objectChanges addObject:objectChange];
	[objectChange release];
}


- (void)controllerDidChangeContent:(NSFetchedResultsController *)controller
{
	[self processChanges];
	
	[_insertedSections removeAllObjects];
	[_deletedSections  removeAllObjects];
	
	[_insertedObjects  removeAllObjects];
	[_deletedObjects   removeAllObjects];
	[_updatedObjects   removeAllObjects];
	[_movedObjects     removeAllObjects];
}

@end

#pragma mark -

@implementation SSSectionChange

@synthesize sectionInfo = _sectionInfo;
@synthesize sectionIndex = _sectionIndex;
@synthesize changeType = _changeType;

- (id)initWithSectionInfo:(id <NSFetchedResultsSectionInfo>)aSectionInfo
                    index:(NSUInteger)aSectionIndex
               changeType:(NSFetchedResultsChangeType)aChangeType
{
	if ((self = [super init]))
	{
		self.sectionInfo = aSectionInfo;
		self.sectionIndex = aSectionIndex;
		self.changeType = aChangeType;
	}
	return self;
}


- (NSString *)changeTypeString
{
	switch (_changeType)
	{
		case NSFetchedResultsChangeInsert : return @"Insert";
		case NSFetchedResultsChangeDelete : return @"Delete";
	}
	
	return nil;
}


- (NSString *)description
{
	return [NSString stringWithFormat:@"<SSSectionChange changeType(%@) index(%lu)>",
			[self changeTypeString], _sectionIndex];
}


- (void)dealloc
{
	self.sectionInfo = nil;
	
	[super dealloc];
}

@end

#pragma mark -

@implementation SSObjectChange

@synthesize object = object_object;
@synthesize indexPath = _indexPath;
@synthesize changeType = _changeType;
@synthesize changedIndexPath = _changedIndexPath;

- (id)initWithObject:(id)anObject
           indexPath:(NSIndexPath *)anIndexPath
          changeType:(NSFetchedResultsChangeType)aChangeType
        newIndexPath:(NSIndexPath *)aNewIndexPath
{
	if ((self = [super init]))
	{
		self.object = anObject;
		self.indexPath = anIndexPath;
		self.changeType = aChangeType;
		self.changedIndexPath = aNewIndexPath;
	}
	return self;
}


- (NSString *)changeTypeString
{
	switch (_changeType)
	{
		case NSFetchedResultsChangeInsert : return @"Insert";
		case NSFetchedResultsChangeDelete : return @"Delete";
		case NSFetchedResultsChangeMove   : return @"Move";
		case NSFetchedResultsChangeUpdate : return @"Update";
	}
	
	return nil;
}


- (NSString *)stringFromIndexPath:(NSIndexPath *)ip
{
	if (ip == nil) return @"nil";
	
	return [NSString stringWithFormat:@"[%lu,%lu]", ip.section, ip.row];
}


- (NSString *)description
{
	return [NSString stringWithFormat:@"<SSObjectChange changeType(%@) indexPath(%@) newIndexPath(%@)>", 
			[self changeTypeString],
			[self stringFromIndexPath:_indexPath],
			[self stringFromIndexPath:_changedIndexPath]];
}


- (void)dealloc
{
	self.object = nil;
	self.indexPath = nil;
	self.changedIndexPath = nil;
	
	[super dealloc];
}

@end
