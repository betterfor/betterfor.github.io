# slice的设计


在Golang语言开发过程中，我们经常会用到数组和切片数据结构，数组是固定长度的，而切片是可以扩张的数组，那么切片底层到底有什么不同？接下来我们来详细分析一下内部实现。

## 一、内部数据结构

首先我们来看一下数据结构

```go
type slice struct {
    array unsafe.Pointer// 数据
    len int             // 长度
    cap int             // 容量
}
```
这里的`array`其实是指向切片管理的内存块首地址，而`len`就是切片的实际使用大小，`cap`就是切片的容量。



我们可以通过下面的代码输出slice：

```go
package main

import (
	"fmt"
	"unsafe"
)

func main() {
	data := make([]int,0,3)

	fmt.Println(unsafe.Sizeof(data),len(data),cap(data))
	// Output: 24,0,3

	// 通过指针方式拿到切片内部的值
	ptr := unsafe.Pointer(&data)
	opt := (*[3]int)(ptr)

	fmt.Println(opt[0],opt[1],opt[2])
	// Output: 824634891936,0,3

	data = append(data, 4)
	fmt.Println(unsafe.Sizeof(data))
	// Output: 24

	shallowCopy := data[:1]
	ptr1 := unsafe.Pointer(&shallowCopy)
	opt1 := (*[3]int)(ptr1)

	fmt.Println(opt1[0])
	// Output: 824634891936
}
```

这么分析下来，我们可以了解如下内容：

- 切片的数据结构大小是24，int占8字节，指针占8字节
- 在不发生扩容的情况下，切片指向的首地址不变
- 常用的关于切片的方法有`make`，`copy`

## 二、声明

使用一个切片通常有两种方法：

一种是`var slice []int`，称为声明；

另一种是`slice = make([]int, len, cap)`这种方法，称为分配内存。

## 三、创建`make`

创建一个slice，实质上是在分配内存。

```go
func makeslice(et *_type, len, cap int) unsafe.Pointer {
    // 获取需要申请的内存大小
	mem, overflow := math.MulUintptr(et.size, uintptr(cap))
	if overflow || mem > maxAlloc || len < 0 || len > cap {
		mem, overflow := math.MulUintptr(et.size, uintptr(len))
		if overflow || mem > maxAlloc || len < 0 {
			panicmakeslicelen() // 超过内存限制|超过最大分配量|长度小于0
		}
		panicmakeslicecap() // 长度大于容量
	}
    // 分配内存
    // runtime/malloc.go
	return mallocgc(mem, et, true)
}
```

这里跟一下细节，`math.MulUintptr`是基于底层的指针计算乘法的，这样计算不会导致超出int大小，这个方法在后面会经常用到。

```go
func MulUintptr(a, b uintptr) (uintptr, bool) {
	if a|b < 1<<(4*sys.PtrSize) || a == 0 { // sys.PtrSize=8
		return a * b, false // a和b都小于32位，乘积肯定小于64位
	}
	overflow := b > MaxUintptr/a // MaxUintptr= ^uintptr(0)，也就是64个1
	return a * b, overflow
}
```

同样，对于int64的长度，也有对应的方法

```go
func makeslice64(et *_type, len64, cap64 int64) unsafe.Pointer {
	len := int(len64)
	if int64(len) != len64 {
		panicmakeslicelen()
	}

	cap := int(cap64)
	if int64(cap) != cap64 {
		panicmakeslicecap()
	}

	return makeslice(et, len, cap)
}
```

而实际分配内存的操作调用`mallocgc`这个分配内存的函数，这个函数以后再分析。

## 四、扩容机制

我们了解切片和数组最大的不同就是切片能够自动扩容，接下来看看切片是如何扩容的

```go
func growslice(et *_type, old slice, cap int) slice {
    // 前置条件
	if cap < old.cap {
		panic(errorString("growslice: cap out of range"))
	}
    
    // 如果新切片的长度为0，返回空数据，长度为旧切片的长度
	if et.size == 0 { 
		return slice{unsafe.Pointer(&zerobase), old.len, cap}
	}

    // 1、先记录原先的容量
	newcap := old.cap
    // 2、尝试2倍扩容
	doublecap := newcap + newcap
	if cap > doublecap { 
         // 如果指定容量大于原有容量的2倍，则按新增容量申请
		newcap = cap
	} else {
        // 3、如果指定容量小于原容量2倍，则按以下的计算方式为新容量
		if old.len < 1024 { // 如果原容量小于1024，新容量是原容量的2倍
			newcap = doublecap
		} else { // 原容量大于1024，按原容量的1.25倍递增
			for 0 < newcap && newcap < cap {
				newcap += newcap / 4
			}
			if newcap <= 0 { // 校验容量是否溢出
				newcap = cap
			}
		}
	}

	var overflow bool
	var lenmem, newlenmem, capmem uintptr
	// 为加速计算（不用乘除法）
    // 对于2的幂，使用变位处理
    // 下面的处理使内存对齐
	switch {
	case et.size == 1:
		lenmem = uintptr(old.len)
		newlenmem = uintptr(cap)
		capmem = roundupsize(uintptr(newcap))
		overflow = uintptr(newcap) > maxAlloc
		newcap = int(capmem)
	case et.size == sys.PtrSize:
		lenmem = uintptr(old.len) * sys.PtrSize
		newlenmem = uintptr(cap) * sys.PtrSize
		capmem = roundupsize(uintptr(newcap) * sys.PtrSize)
		overflow = uintptr(newcap) > maxAlloc/sys.PtrSize
		newcap = int(capmem / sys.PtrSize)
	case isPowerOfTwo(et.size): // 2的幂
		var shift uintptr
		if sys.PtrSize == 8 {
			// Mask shift for better code generation.
			shift = uintptr(sys.Ctz64(uint64(et.size))) & 63
		} else {
			shift = uintptr(sys.Ctz32(uint32(et.size))) & 31
		}
		lenmem = uintptr(old.len) << shift
		newlenmem = uintptr(cap) << shift
		capmem = roundupsize(uintptr(newcap) << shift)
		overflow = uintptr(newcap) > (maxAlloc >> shift)
		newcap = int(capmem >> shift)
	default:
		lenmem = uintptr(old.len) * et.size
		newlenmem = uintptr(cap) * et.size
		capmem, overflow = math.MulUintptr(et.size, uintptr(newcap))
		capmem = roundupsize(capmem)
		newcap = int(capmem / et.size)
	}

	// 判断是否会溢出，是否会超出可分配
	if overflow || capmem > maxAlloc {
		panic(errorString("growslice: cap out of range"))
	}

    // 内存分配
	var p unsafe.Pointer
	if et.ptrdata == 0 {
		p = mallocgc(capmem, nil, false)
		// 回收内存
		memclrNoHeapPointers(add(p, newlenmem), capmem-newlenmem)
	} else {
		// Note: can't use rawmem (which avoids zeroing of memory), because then GC can scan uninitialized memory.
		p = mallocgc(capmem, et, true)
		if lenmem > 0 && writeBarrier.enabled { // gc
			// Only shade the pointers in old.array since we know the destination slice p
			// only contains nil pointers because it has been cleared during alloc.
			bulkBarrierPreWriteSrcOnly(uintptr(p), uintptr(old.array), lenmem)
		}
	}
    // 数据拷贝
	memmove(p, old.array, lenmem)

	return slice{p, old.len, newcap}
}
```

这里可以看到，`growslice`是返回了一个新的`slice`，也就是说如果发生了扩容，会发生拷贝。

所以我们在使用过程中，如果预先知道容量，可以预先分配好容量再使用，能提高运行效率。

## 五、深拷贝

`copy`这个函数在内部实现为`slicecopy`

```go
func slicecopy(to, fm slice, width uintptr) int {
    // 前置条件
	if fm.len == 0 || to.len == 0 {
		return 0
	}

	n := fm.len
	if to.len < n {
		n = to.len
	}
    // 元素长度为0，直接返回
	if width == 0 {
		return n
	}

	size := uintptr(n) * width
    // 拷贝内存
	if size == 1 {
		*(*byte)(to.array) = *(*byte)(fm.array) // known to be a byte pointer
	} else {
		memmove(to.array, fm.array, size)
	}
	return n
}
```

还有关于字符串的拷贝

```go
func slicestringcopy(to []byte, fm string) int {
    // 前置条件
	if len(fm) == 0 || len(to) == 0 {
		return 0
	}

	n := len(fm)
	if len(to) < n {
		n = len(to)
	}

	memmove(unsafe.Pointer(&to[0]), stringStructOf(&fm).str, uintptr(n))
	return n
}
```

这里显示了可以把`string`拷贝成`[]byte`，不能把`[]byte`拷贝成`string`。

## 六、总结

1、切片的数据结构是 array内存地址，len长度，cap容量

2、`make`的时候需要注意 容量 * 长度 分配的内存大小要小于2^64^，并且要小于可分配的内存量，同时长度不能大于容量。

3、内存增长的过程：

- 如果指定的容量大于原先的2倍，就按照指定的容量
- 如果原先的容量小于1024，按2倍容量扩张
- 如果原先的容量大于1024，就按1.25倍扩张，会小于指定的容量
- 容量大小确定完之后，会进行内存对齐

4、当发生内存扩容时，会发生拷贝数据的现象，影响程序运行的效率，如果可以，要先分配好指定的容量

5、关于拷贝，可以把`string`拷贝成`[]byte`，不能把`[]byte`拷贝成`string`。
