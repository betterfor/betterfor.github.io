# 垃圾回收


垃圾回收（Garbage Collection，简称GC）是Go语言中提供的内存管理机制，自动释放不需要的内存对象。GC过程无需程序员手动执行。

Go在GC的演进过程中经历很多次变革：

| 版本 | GC算法                      |
| ---- | --------------------------- |
| v1.1 | STW（Stop the world）       |
| v1.3 | Mark STW，Sweep（标记清除） |
| v1.5 | 三色标记                    |
| v1.8 | 三色标记+写屏障             |

## 一、标记-清除算法

此算法主要有两个步骤

- 标记
- 清除

### 1.1、具体步骤

1、暂停程序业务逻辑，分类出可达和不可达的对象，然后做上标记。

图示表示程序与对象的可达关系，目前程序的可达对象有1-2-3，4-7共5个对象

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_mark_sweep1.png)

2、开始标记，程序找出它所有可达的对象，并做上标记

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_mark_sweep2.png)

3、标记完之后，开始清除未标记的对象

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_mark_sweep3.png)

mark and sweep算法在执行时，需要程序暂停，即STW，STW过程中，CPU不执行用户代码，全部用于垃圾回收，这个过程影响很大。

4、STW结束，程序继续运行，直到程序生命周期结束。

### 1.2、缺点

- STW，让程序暂停，程序出现卡顿
- 标记需要扫描整个heap
- 清除数据会产生heap碎片

Go1.3版本之前按照`启动STW`->`Mark标记`->`Sweep清除`->`停止STW`这个流程，全部的GC时间都在STW范围内，Go1.3版本做了简单优化，因为`Sweep清除`可以不需要STW停止，因为这些对象都是不可达对象，不会出现回收写冲突的问题。

## 二、三色标记法

Go中的垃圾回收主要应用三色标记法，GC过程和其他goroutine可并发运行，但需要一定时间STW。

### 2.1、具体步骤

三色标记法其实就是通过三个阶段的标记对象的状态。

1、每次新创建的对象，默认都被标记为“白色”

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记1.png)



我们将程序展开

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记2.png)

2、每次GC回收开始，会从根结点开始遍历所有对象，把遍历到的对象从白色集合放入到灰色集合中

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记3.png)

3、遍历灰色集合，将灰色引用的对象从白色集合放入灰色集合，之后将此灰色对象放入黑色集合

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记4.png)

4、重复第三步，直到灰色中无任何对象

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记5.png)

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_三色标记6.png)

当我们全部的可达对象遍历完后，灰色标记中不再存在灰色对象，全部内存的数据只有黑色和白色。那么黑色对象就是程序逻辑可达（需要）的对象，是合法有用的数据，支持程序运行的数据，不可删除，而白色对象就是全部不可达数据，就是内存中的垃圾数据，需要被清除。

5、回收所有的白色对象，也就是回收垃圾

可以看出这里面可能会有很多并发流程都会被扫描，执行并发流程的内存可能会互相依赖，为了在GC过程中保护数据安全，在三色标记前加STW，在扫描确定黑白对象后放开STW。但是很明显这样的GC扫描性能太低了。

如果不添加STW，在标记完黑色对象后，有可能黑色对象重新指向新的对象，而这个新的对象是不能被扫描到的。

## 三、屏障机制

让GC满足以下两种情况时，保证对象不丢失。

### 3.1、强-弱三色不等式

1、强三色不等式

不存在黑色对象引用到白色对象的指针。也就是说，强制性的不允许黑色对象引用白色对象，只能引用灰色对象，这样就不会出现白色对象被误删的情况。

2、弱三色不等式

所有被黑色对象引用的白色对象都处于灰色保护状态。

黑色对象可以引用白色对象，白色对象存在其他灰色对象对它的引用，或可达它的链路上游存在灰色对象。这样实则是黑色对象引用白色对象，白色对象处于一个被删除的状态，但是上游灰色对象的引用，可以保护白色对象，使其安全。

为了遵循上述两种方式，GC算法演进到两种屏障方式，“插入屏障”和“删除屏障”

### 3.2、插入屏障

在A对象引用B对象时，B对象被标记为灰色。（将B挂在A下游，B必须被标记为灰色）

满足强三色不等式。

插入屏障机制在栈空间的对象操作不使用，仅仅使用在堆空间对象的操作中。

1、程序创建时，全部对象标记为白色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障1.png)

2、遍历Root Set，得到灰色对象

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障12.png)

3、遍历灰色对象，将可达对象，从白色标记为灰色，灰色标记为黑色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障3.png)

4、由于并发特性，此时向对象1添加对象8，对象4添加对象9，触发插入屏障机制，对象1不触发

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障4.png)

5、由于插入写屏障，对象9变成灰色对象，对象8依然为白色对象

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障5.png)

6、继续上述流程进行三色标记，知道没有灰色节点

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障6.png)

7、在准备回收白色对象前，重新扫描遍历一次栈空间，此时加STW暂停保护栈，防止外界干扰（有新的白色被黑色添加）

8、在STW中，将栈中的对象一次三色标记，知道没有灰色节点

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_插入屏障7.png)

10、最后将栈和堆空间的全部白色对象清除，这次STW大约时间在10~100ms之间

### 3.3、删除屏障

被删除的对象，如果本身为灰色或白色，那么标记为灰色。

满足弱三色不等式

1、程序初创建，所有对象被标记为白色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_删除屏障1.png)

2、遍历Root Set，得到灰色节点

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_删除屏障2.png)

3、灰色对象1删除对象5，对象5被标记为灰色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_删除屏障3.png)

4、继续遍历灰色对象，将可达对象从白色标记为灰色，遍历后的灰色标记为黑色

5、继续循环上述流程，知道没有灰色节点

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_删除屏障4.png)

6、清除白色节点

这种回收方式精度低，一个对象即时被删除了也可以活过这一轮GC，在下一轮GC被清除掉

## 四、混合写屏障

插入写屏障和删除写屏障的缺点：

- 插入写屏障：结束时需要STW来重新扫描栈，标记栈上引用的白色对象存活
- 删除写屏障：回收精度低，GC开始时STW扫描堆栈来记录快照，这个过程会保护开始时刻的所有的存活对象

Go1.8引入混合写屏障机制，避免了对栈的重复扫描过程，极大减少了STW的时间。



1、GC开始将栈上的对象全部扫描并标记为黑色（之后不再进行第二次重复扫描，无需STW）

2、GC期间，任何在栈上创建的新对象，都标记为黑色

3、被删除的对象标记为灰色

4、被添加的对象标记为灰色

### 具体场景

1、GC开始，默认为白色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_混合写屏障1.png)

2、优先扫描栈对象，将可达对象标记为黑色

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/barrier_混合写屏障2.png)

---

场景一：对象被一个堆对象引用删除，成为栈对象的下游

1、将对象7添加到对象1下游，因为栈不启用写屏障，所以直接挂在下面

2、对象4删除对象7的引用关系，因为对象4是堆区，所以触发写屏障，标记被删除的对象7为灰

场景二：对象被一个栈对象删除引用，成为另一个栈对象的下游

1、新建一个对象9在栈上，混合写屏障中，GC过程中任何新创建的对象均标记为黑色

2、对象9添加下游引用栈对象3，直接添加，栈不启用屏障，无屏障效果

3、对象2删除对象3的引用关系，是直接删除，栈不启用屏障，无屏障效果

场景三：对象被一个堆对象引用删除，称为另一个堆对象的下游

1、新建一个堆对象10，已经被扫描标记为黑色

2、堆对象10添加下游引用堆对象7，触发屏障机制，被添加的对象标记为灰色

场景四：对象从一个栈对象删除引用，成为另一个堆对象的下游

1、栈对象1删除栈对象2的引用

2、堆对象4删除对象7的引用关系，添加引用到对象2

3、对象4在删除的时候触发写屏障，标记被删除的对象7为灰色

---

混合写屏障满足弱三色不等式，结合了删除写屏障和插入写屏障的优点，只需要在开始时并发扫描各个goroutine的栈，使其变黑并一直保持，这个过程不需要STW，而标记结束后，因为栈在扫描后始终是黑色的，也无需再进行re-scan操作了，减少了STW的时间。

## 五、垃圾回收过程

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/03/11/golang_gc.jpg)

### 5.1、Marking setup

为了打开写屏障，必须停止每个goroutine，让垃圾收集器观察并等待每个goroutine进行函数调用，等待函数调用是为了保证goroutine停止时处于安全点。

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/marking_setup.webp)

下面的代码中，由于`for{}` 循环所在的goroutine 永远不会中断，导致始终无法进入STW阶段，资源浪费；Go 1.14 之后，此类goroutine 能被异步抢占，使得进入STW的时间不会超过抢占信号触发的周期，程序也不会因为仅仅等待一个goroutine的停止而停顿在进入STW之前的操作上。

```go
func main() {
    go func() {
        for {
        }
    }()
    time.Sleep(time.Milliecond)
    runtime.GC()
    println("done")
}
```

### 5.2、Marking

一旦写屏障打开，垃圾收集器就开始标记阶段。

标记阶段需要标记在堆内存中仍然在使用中的值。首先检查所有现goroutine的堆栈，以找到堆内存的根指针。然后收集器必须从那些根指针遍历堆内存图，标记可以回收的内存。

当存在新的内存分配时，会暂停分配内存过快的那些 goroutine，并将其转去执行一些辅助标记（Mark Assist）的工作，从而达到放缓继续分配、辅助 GC 的标记工作的目的。

### 5.3、Mark终止

关闭写屏障，执行各种清理任务（STW）

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/12/21/mark_stop.webp)

5.4、Sweep清理

清理阶段用于回收标记阶段中标记出来的可回收内存。当应用程序goroutine尝试在堆内存中分配新内存时，会触发该操作，清理导致的延迟和吞吐量降低被分散到每次内存分配时。

## 六、如何触发GC

1、`runtime.GC()`强制触发GC

2、再分配内存时，判断当前内存是否达到阈值会触发新一轮GC（比如当前为4MB，GOGC=100，4MB+4MB*GOGC/100）

3、上次GC间隔达到了runtime.forcegcperiod(默认2分钟)，会启动GC

**调优方法**

1、合理化内存分配速度

2、降低并复用已经申请的内存

3、调整GOGC

