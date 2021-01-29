# LEETCODE 001. 两数之和


众所周知啊，leetcode有一道"神题"，有多神呢？来看一组数据

![01通过率](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/28/01通过.png)

超过百万的提交，通过率达到一半!!!

那么这道题是哪一题呢？相信很多聪明的小伙伴已经猜出来了，就是第一题。

俗话说，万事开头难，~~只要肯放弃~~，只要肯攀登。

那么今天，我们就来看看这道题到底有多难。

---

**请看题**

给定一个整数数组`nums`和一个整数目标值`target`，
请你在该数组中找出**和为目标值**的那**两个**整数，
并返回它们的数组下标。

咦~，看起来好像很简单，我们只要让每个数和他后面的数依次相加，比较`target`，就能得到结果。

话不多说，立刻来手写代码
```go
func twoSum(nums []int,target int) []int {
    for i := 0; i < len(nums); i++ {
        for j := i+1; j < len(nums); j++ {
            if nums[i] + nums[j] == target {
                return []int{i,j}
            }    
        }
    }
    return nil
}
```

执行->提交

![001-01](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/28/001-01.png)

有问题~ 属实有问题~

居然还有将近`8%`的用户超过了这方法，
这可是时间复杂度达到O(n^2^),空间复杂度达到O(1)的**暴力法**啊。

那要怎么超过其他人呢？

两项都击败可能不好处理，但用一半击败还是有机会的。

通常会有两种方法，拿时间换空间和那空间换时间。

而我们的**暴力法**的空间已达极致了，不能被换了，所以只能拿空间换时间。

那是要用到哈希表了，用哈希表记录元素及索引，然后遍历元素进行比较。

![001-02](https://gitee.com/zongl/cloudImage/raw/master/images/2021/01/28/001-02.png)

时间复杂度达到O(n),空间复杂度达到O(n),成功把内存消耗拉大~

但是用时确没有变化。连续提交了几次也没什么大的改变。

于是，跑去题解区查看有没有更优质的题解。

查看后发现，算法思想基本上差不多，只是不同的语言提交的时间和空间差距。

查看同语言的提交，发现了一个颇有意思的提交

```go
func twoSum(nums []int, target int) []int {
    var ids []int
    numLen := len(nums)
    idx := make(chan int, numLen - 1)
    diffIdx := make(chan []int)
    // 接收一个数组的索引值
    for i := 0; i < numLen - 1; i ++ { // 
        idx <- i
        go func(j chan int)  {
            a := <-j  // 取出下标            
            diff := target - nums[a] // 获取被减数           
            tmp := nums[a + 1:]    
            flag, index :=  GetIndex(diff, tmp)  // 被减数是否存在 nums[a:] 数组中，存在就返回对应的下标            
            if flag { // 被除数的下表存在 返回对应的下标
                diffIdx <- []int{a, a + 1 + index}
                // diffIdx <- ids
            }        
        } (idx)
    }
    select {
        case ids = <- diffIdx:
        return ids
    }
    return ids
}

func GetIndex(n int, arr []int) (bool, int) {
    for i := 0; i < len(arr); i ++ {    
        if arr[i] == n {            
            return true, i
        }
    }
    return false, 0
}
```

当然啦，不是鼓励大家使用这种方法，因为最终我们是要回归到算法的，不要过多使用语言特性。