# panic的设计


GO中的`defer`会在当前函数返回前执行传入的函数，常用于关闭文件描述符，关闭链接及解锁等操作。

Go语言中使用`defer`时会遇到两个常见问题：

- `defer`的调用时机和执行顺序
- `defer`调用函数使用传值的方法会执行函数，导致不符预期的结果

接下来我们来详细处理这两个问题。

## 一、defer

官方有段对`defer`的解释：

>  每次`defer`语句执行时，会把函数“压栈”，函数的参数会被拷贝下来，当外层函数退出时，defer函数按照定义的逆序执行，如果defer执行的函数为nil，那么会在最终调用函数产生panic。

这里我们先来一道经典的面试题

```go
func main() {
	a,b := 1,2
	defer cal("1",a,cal("10",a,b))
	a = 0
	defer cal("2",a,cal("20",a,b))
}

func cal(index string, a, b int) int {
	ret := a + b
	fmt.Println(index,a,b,ret)
	return ret
}
```

你觉得这个会打印什么？

---

输出结果：

```text
10 1 2 3
20 0 2 2
2 0 2 2
1 1 3 4
```

这里是遵循先入后出的原则，同时保留当前变量的值。

把这道题简化一下：

```go
func main() {
	var i = 1
	defer fmt.Println(i)

	i = 4
}
```

---

输出结果

```text
1
```

上述代码输出似乎不符合预期，这个现象出现的原因是什么呢？经过分析，我们发现调用`defer`关键字会立即拷贝函数中引用的外部参数，所以`fmt.Println(i)`的这个`i`是在调用`defer`的时候就已经赋值了，所以会直接打印`1`。

想要解决这个问题也很简单，只需要向`defer`关键字传入匿名函数

```go
func main() {
	var i = 1
	defer func() {
		fmt.Println(i)
	}()

	i = 4
}
```

## 二、数据结构

```go
// 占用48字节的内存，link把所有的_defer串成一个链表。
// _defer 只是一个header，结构紧跟的是延迟函数的参数和返回值的空间，大小由 siz 决定
type _defer struct {
	// 参数和返回值的内存大小
	siz     int32 
	started bool
	// 区分该结构是在栈上分配还是在堆上分配
	heap bool
	openDefer bool
	// sp 计数器值，栈指针
	sp uintptr // sp at time of defer
	// pc 计数器值，程序计数器
	pc uintptr // pc at time of defer
	// defer 传入的函数地址，也就是延后执行的函数
	fn     *funcval // can be nil for open-coded defers
    // 触发延迟调用的结构体
	_panic *_panic  
    // 下一个要被执行的延迟函数
	link   *_defer  
}
```

这里把一些垃圾回收使用的字段忽略了。

### 2.1、执行机制

中间代码生成阶段`cmd/compile/internal/gc/ssa.go`会处理程序中的`defer`，该函数会根据条件不同，使用三种机制来处理该关键字

```go
func (s *state) stmt(n *Node) {
	...
	switch n.Op {
	case ODEFER:
		if Debug_defer > 0 {
			var defertype string
			if s.hasOpenDefers {
				defertype = "open-coded"
			} else if n.Esc == EscNever {
				defertype = "stack-allocated"
			} else {
				defertype = "heap-allocated"
			}
			Warnl(n.Pos, "%s defer", defertype)
		}
		if s.hasOpenDefers {
             // 开放编码
			s.openDeferRecord(n.Left) 
		} else {
             // 堆分配
			d := callDefer
			if n.Esc == EscNever {
                 // 栈分配
				d = callDeferStack
			}
			s.call(n.Left, d)
		}
	}
}
```

开放编码、堆分配和栈分配是`defer`关键字的三种方法，而Go1.14加入的开放编码，使得关键字开销可以忽略不计。

### 2.2、堆分配

`call`方法会为所有函数和方法调用生成中间代码，工作内容：

- 获取需要执行的函数名、闭包指针、代码指针和函数调用的接收方
- 获取栈地址并将函数或方法写入栈中
- 调用`newValue1A`及相关函数生成函数调用的中间代码
- 如果当前函数的调用函数是`defer`，那么会单独生成相关的结束代码块
- 获取函数的返回值并结束当前调用

```go
func (s *state) call(n *Node, k callKind) *ssa.Value {
	var call *ssa.Value
	if k == callDeferStack {
        // 在栈上初始化defer结构体
        ...
    } else {
        ...
        switch {
        case k == callDefer:
			call = s.newValue1A(ssa.OpStaticCall, types.TypeMem, deferproc, s.mem())
            ...
        }
        call.AuxInt = stksize
    }
    s.vars[&memVar] = call
}
```

`defer`关键字在运行时会调用`deferproc`，这个函数实现在`src/runtime/panic.go`里，接受两个参数：参数的大小和闭包所在的地址。

编译器不仅将`defer`关键字转成`deferproc`函数，还会通过以下三种方式为所有调用`defer`的函数末尾插入`deferreturn`的函数调用

1、在`cmd/compile/internal/gc/walk.go`的`walkstmt`函数中，在遇到`ODEFFER`节点时会执行`Curfn.Func.SetHasDefer(true)`，设置当前函数的`hasdefer`属性

2、在`ssa.go`的`buildssa`会执行`s.hasdefer = fn.Func.HasDefer()`更新`hasdefer`

3、在`exit`中会根据`hasdefer`在函数返回前插入`deferreturn`的函数调用

```go
func (s *state) exit() *ssa.Block {
	if s.hasdefer {
		if s.hasOpenDefers {
			...
		} else {
			s.rtcall(Deferreturn, true, nil)
		}
	}
    ...
}
```

#### 2.2.1、创建延迟调用

`runtime.deferproc`为`defer`创建了一个`runtime._defer`结构体、设置它的函数指针`fn`、程序计数器`pc`和栈指针`sp`并将相关参数拷贝到相邻的内存空间中

```go
func deferproc(siz int32, fn *funcval) { // arguments of fn follow fn
	gp := getg()
	if gp.m.curg != gp {
		// go code on the system stack can't defer
		throw("defer on system stack")
	}

	// 获取caller的sp寄存器和pc寄存器值
	sp := getcallersp()
	argp := uintptr(unsafe.Pointer(&fn)) + unsafe.Sizeof(fn)
	callerpc := getcallerpc()

	// 分配 _defer 结构
	d := newdefer(siz)
	if d._panic != nil {
		throw("deferproc: d.panic != nil after newdefer")
	}
	// _defer 结构初始化
	d.link = gp._defer
	gp._defer = d
	d.fn = fn
	d.pc = callerpc
	d.sp = sp
	switch siz {
	case 0:
		// Do nothing.
	case sys.PtrSize:
		*(*uintptr)(deferArgs(d)) = *(*uintptr)(unsafe.Pointer(argp))
	default:
		memmove(deferArgs(d), unsafe.Pointer(argp), uintptr(siz))
	}

	return0()
}
```

最后调用的`return0`是唯一一个不会触发延迟调用的函数，可以避免`deferreturn`的递归调用。

`newdefer`的分配方式是从`pool`缓存池中获取：

- 从调度器的`deferpool`中取出结构体并将该结构体加入到当前goroutine的缓存池中
- 从goroutine的`deferpool`中取出结构体
- 通过`mallocgc`从堆上创建一个新的结构体

```go
func newdefer(siz int32) *_defer {
	var d *_defer
	sc := deferclass(uintptr(siz))
	gp := getg() // 获取当前的goroutine
	// 从pool缓存池中分配，如果没有则mallocgc从堆上分配内存
	if sc < uintptr(len(p{}.deferpool)) {
		pp := gp.m.p.ptr()
		if len(pp.deferpool[sc]) == 0 && sched.deferpool[sc] != nil {
			for len(pp.deferpool[sc]) < cap(pp.deferpool[sc])/2 && sched.deferpool[sc] != nil {
					d := sched.deferpool[sc]
					sched.deferpool[sc] = d.link
					d.link = nil
					pp.deferpool[sc] = append(pp.deferpool[sc], d)
				}
		}
		if n := len(pp.deferpool[sc]); n > 0 {
			d = pp.deferpool[sc][n-1]
			pp.deferpool[sc][n-1] = nil
			pp.deferpool[sc] = pp.deferpool[sc][:n-1]
		}
	}
	if d == nil {
		total := roundupsize(totaldefersize(uintptr(siz)))
			d = (*_defer)(mallocgc(total, deferType, true))
	}
	d.siz = siz
	d.heap = true
	return d
}
```

这三种方式取到的结构体`_defer`，都会被添加到链表的队头，这也是为什么`defer`按照后进先出的顺序执行。

#### 2.2.2、执行延迟调用

```go
func deferreturn(arg0 uintptr) {
    // 获取当前的goroutine
	gp := getg()   
    // 拷贝延迟函数到变量d上
	d := gp._defer 
	// 如果延迟函数不存在则返回
	if d == nil {
		return
	}
	// 获取caller函数的sp寄存器
	sp := getcallersp()
	if d.sp != sp {
         // 说明这个_defer 不是在该caller函数注册的
		return
	}

	switch d.siz {
	case 0:
		// Do nothing.
	case sys.PtrSize:
		*(*uintptr)(unsafe.Pointer(&arg0)) = *(*uintptr)(deferArgs(d))
	default:
		memmove(unsafe.Pointer(&arg0), deferArgs(d), uintptr(d.siz))
	}
    // 获取要调用的函数
	fn := d.fn        
     // 重置函数
	d.fn = nil   
    // 把下一个_defer结构体依附到goroutine上
	gp._defer = d.link 
    // 释放_defer（主要是堆回收，因为栈上的随函数执行完会自动回收）
	freedefer(d)       
	_ = fn.fn
    // 调用该函数
	jmpdefer(fn, uintptr(unsafe.Pointer(&arg0))) 
}
```

`deferreturn`就是从链表的队头取出并调用`jmpdefer`传入需要执行的函数和参数。

该函数只有在所有延迟函数都执行后才会返回。

### 2.3、栈分配

如果我们能够将部分结构体分配到栈上就可以节约内存分配带来的额外开销。

在`call`函数中有在栈上分配

```go
func (s *state) call(n *Node, k callKind) *ssa.Value {
	var call *ssa.Value
	if k == callDeferStack {
        t := deferstruct(stksize)
        ...
        call = s.newValue1A(ssa.OpStaticCall, types.TypeMem, deferprocStack, s.mem())
		if stksize < int64(Widthptr) {
			stksize = int64(Widthptr)
		}
		call.AuxInt = stksize
    }
    ...
}
```

在运行期间`deferprocStack`只需要设置一些未在编译期间初始化的字段，就可以将栈上的`_defer`追加到函数的链表上。

```go
func deferprocStack(d *_defer) {
	gp := getg()
	if gp.m.curg != gp {
		// go code on the system stack can't defer
		throw("defer on system stack")
	}
	// siz 和 fn在进入到这个函数之前已经赋值
	d.started = false
	// 标明是栈的内存
	d.heap = false
	d.openDefer = false
	// 获取到caller函数的sp寄存器值和pc寄存器
	d.sp = getcallersp()
	d.pc = getcallerpc()
	d.framepc = 0
	d.varp = 0
	*(*uintptr)(unsafe.Pointer(&d._panic)) = 0
	*(*uintptr)(unsafe.Pointer(&d.fd)) = 0
	*(*uintptr)(unsafe.Pointer(&d.link)) = uintptr(unsafe.Pointer(gp._defer))
	*(*uintptr)(unsafe.Pointer(&gp._defer)) = uintptr(unsafe.Pointer(d))

	return0()
}
```

除了分配的位置和堆的不同，其他的大致相同。

### 2.4、开放编码

Go语言在1.14中通过开放编码实现`defer`关键字，使用代码内联优化`defer`关键的额外开销并引入函数数据`funcdata`管理`panic`的调用，该优化可以将 `defer` 的调用开销从 1.13 版本的 ~35ns 降低至 ~6ns 左右。

然而开放编码作为一种优化 `defer` 关键字的方法，它不是在所有的场景下都会开启的，开放编码只会在满足以下的条件时启用：

1. 函数的 `defer` 数量少于或者等于 8 个；
2. 函数的 `defer` 关键字不能在循环中执行；
3. 函数的 `return` 语句与 `defer` 语句的乘积小于或者等于 15 个；

#### 2.4.1、启动优化

```go
const maxOpenDefers = 8

func walkstmt(n *Node) *Node {
    ...
    switch n.Op {
    case ODEFER:
		Curfn.Func.SetHasDefer(true)
		Curfn.Func.numDefers++
		if Curfn.Func.numDefers > maxOpenDefers {
			Curfn.Func.SetOpenCodedDeferDisallowed(true)
		}
		if n.Esc != EscNever {
			Curfn.Func.SetOpenCodedDeferDisallowed(true)
		}
		fallthrough
    }
}
```

如果函数中`defer`关键字的数量多于8个或者`defer`处于循环中，那么就会禁用开放编码优化。

```go
func buildssa(fn *Node, worker int) *ssa.Func {
    ...
	s.hasOpenDefers = Debug['N'] == 0 && s.hasdefer && !s.curfn.Func.OpenCodedDeferDisallowed()
    if s.hasOpenDefers &&
		s.curfn.Func.numReturns*s.curfn.Func.numDefers > 15 {
		s.hasOpenDefers = false
	}
    ...
}
```

可以看到这里，判断编译参数不用`-N`，返回语句的数量和`defer`数量的乘积小于15，会启用开放编码优化。

#### 2.4.2、延迟记录

延迟比特`deferBitsTemp`和延迟记录是使用开放编码实现`defer`的两个最重要的结构，一旦使用开放编码，`buildssa`会在栈上初始化大小为8个比特的`deferBits`

```go
func buildssa(fn *Node, worker int) *ssa.Func {
	if s.hasOpenDefers {
	deferBitsTemp := tempAt(src.NoXPos, s.curfn, types.Types[TUINT8])
	s.deferBitsTemp = deferBitsTemp
	startDeferBits := s.entryNewValue0(ssa.OpConst8, types.Types[TUINT8])
	s.vars[&deferBitsVar] = startDeferBits
	s.deferBitsAddr = s.addr(deferBitsTemp, false)
	s.store(types.Types[TUINT8], s.deferBitsAddr, startDeferBits)
	s.vars[&memVar] = s.newValue1Apos(ssa.OpVarLive, types.TypeMem, deferBitsTemp, s.mem(), false)
	}
}
```

延迟比特中的每一个比特位都表示该位对应的`defer`关键字是否需要被执行。延迟比特的作用就是标记哪些`defer`关键字在函数中被执行，这样就能在函数返回时根据对应的`deferBits`确定要执行的函数。

而`deferBits`的大小为8比特，所以该优化的条件就是`defer`的数量小于8.

而执行延迟调用的时候仍在`deferreturn`

```go
func deferreturn(arg0 uintptr) {
    if d.openDefer {
		done := runOpenDeferFrame(gp, d)
		if !done {
			throw("unfinished open-coded defers in deferreturn")
		}
		gp._defer = d.link
		freedefer(d)
		return
	}
}
```

这里做了特殊的优化，在`runOpenDeferFrame`执行开放编码延迟函数

1、从结构体`_defer`读取`deferBits`，执行函数等信息

2、在循环中依次读取执行函数的地址和参数信息，并通过`deferBits`判断是否要执行

3、调用`reflectcallSave`执行函数

```go
func runOpenDeferFrame(gp *g, d *_defer) bool {
	done := true
	fd := d.fd
	deferBitsOffset, fd := readvarintUnsafe(fd)
	nDefers, fd := readvarintUnsafe(fd)
	deferBits := *(*uint8)(unsafe.Pointer(d.varp - uintptr(deferBitsOffset)))

	for i := int(nDefers) - 1; i >= 0; i-- {
		// 读取函数funcdata地址和参数信息
		var argWidth, closureOffset, nArgs uint32
		argWidth, fd = readvarintUnsafe(fd)
		closureOffset, fd = readvarintUnsafe(fd)
		nArgs, fd = readvarintUnsafe(fd)
		if deferBits&(1<<i) == 0 {
			...
			continue
		}
		closure := *(**funcval)(unsafe.Pointer(d.varp - uintptr(closureOffset)))
		d.fn = closure
		deferArgs := deferArgs(d)
		...
		deferBits = deferBits &^ (1 << i)
		*(*uint8)(unsafe.Pointer(d.varp - uintptr(deferBitsOffset))) = deferBits
		p := d._panic
		reflectcallSave(p, unsafe.Pointer(closure), deferArgs, argWidth)
		if p != nil && p.aborted {
			break
		}
		d.fn = nil
		// These args are just a copy, so can be cleared immediately
		memclrNoHeapPointers(deferArgs, uintptr(argWidth))
		...
	}

	return done
}
```

## 三、总结

1、新加入的`defer`放入队头，执行`defer`时是从队头取函数调用，所以是后进先出

2、通过判断`defer`关键字、`return`数量来判断是否开启开放编码优化

3、调用`deferproc`函数创建新的延迟调用函数时，会立即拷贝函数的参数，函数的参数不会等到真正执行时计算
