MODULE HdDATA
  IMPLICIT NONE
!*****************************************************************
!*   DERIVED TYPES
!*****************************************************************

  ! pointer to type TTermDef
  type pTermDef
    type(TTermDef),pointer    ::  p
  end type pTermDef
  ! TTermDef: Derived type for term definitions in termList
  ! Suppose that i is order of the term
  ! ord          : order of the current term
  ! coord(1:ord) : A list of coordinates in decreasing order. The product of all
  !                coordinates in the list gives the term.
  ! dcTerm(x)    : Pointer to the i-1 order term obtained by removing coordinate
  !                x from the current term.  Not associated if the current term
  !                does not have x in it.
  ! icTerm(x)    : Pointer to i+1 order term obtained by adding coordinate x to
  !                the current term.  Not associated if the higher order term is
  !                not generated yet.
  ! dcCount      : The number of times the last entry is found in coord
  ! pNext        : Pointer to the next term in the list. Null if last entry.
  ! val          : value of the term.  scratch space for Hd evaluation
  ! index        : index in the vectorized list of raw terms.
  type TTermDef
    integer                                       :: ord
    integer,dimension(:),allocatable              :: coord
    type(TTermDef),pointer                        :: pNext=>null()
    type(pTermDef),dimension(:),allocatable       :: dcTerm
    type(pTermDef),dimension(:),allocatable       :: icTerm
    integer                                       :: dcCount
    double precision                              :: val
    integer                                       :: index
  end type TTermDef

  ! derived type for a linked list of TTermDef
  ! nTerms is the total number of terms in the list.
  ! $(last) points to the last existing link.
  ! handle is a dummy first link.  handle%pNext is the first link with
  ! term definitions in it.
  type TTermList
    integer                                       :: nTerms=0
    type(TTermDef),pointer                        :: handle=>null()
    type(TTermDef),pointer                        :: last=>null()
  end type TTermList

  ! derived type for allocatable 3D double precision list
  ! this type is used for storage of derivatives/values of basis matrices
  type T3DDList
    double precision,dimension(:,:,:),pointer :: List=>null()
  end type T3DDList

  ! derived type for one dimensional double precision list
  ! this type is used for storage of Hd coefficients for a certain order
  ! and block.
  type TDList
    double precision,dimension(:),allocatable     :: List
  end type TDList

  ! 2 dimensional double precision list
  type T2DDList
    double precision,dimension(:,:),pointer    :: List=>null()
  end type T2DDList

  ! derived type for integer lists
  type TIList
    integer,dimension(:),allocatable     :: List
  end type TIList
  ! derived type for the definition of one basis matrix
  ! nterms            : number of terms used to expand the current basis
  ! term(nterms)      : list of pointers to all the terms of expansion
  ! coef(nl*nr*nterms): coefficients in front of terms at each matrix entry
  type TMTabBasis
    integer                                       :: nterms=0
    type(pTermDef),dimension(:),allocatable       :: term
    double precision,dimension(:,:,:),allocatable :: coef
    type(TMTabBasis),pointer                      :: pNext=>null()
  end type TMTabBasis

  ! derived type for maptab entries
  type TMaptabEnt
    integer                                       :: nBasis=0
    type(TMTabBasis),pointer                      :: handle=>null()
    type(TMTabBasis),pointer                      :: last=>null()
  end type TMaptabEnt

!*****************************************************************
!*    MODULE VARIABLES
!*****************************************************************

  ! BASIC PROPERTIES OF Hd
  INTEGER                                         :: order  !total order of Taylor expansion
  INTEGER                                         :: CpOrder!total order for off-diagonal coupling blocks 
  INTEGER                                         :: ncoord !total number of scaled coords
  INTEGER                                         :: nstates!number of electronic states

  !States are partitioned into groups for the implementation of multidimensional irreps.
  !This section contains the variable and lists that defines those groups, as well as the
  !mappings between group index and state indicies.
  !Hd is therefore partitioned into blocks, each containing all the entries whose rows are
  !from the same group I, columns from group J.
  INTEGER                                         :: nGroups !total number of groups
  INTEGER,DIMENSION(:),ALLOCATABLE                :: GrpLen  !Number of states in each group
  INTEGER                                         :: nblks   !number of UNIQUE blocks
  ! RowGrp(ColGrp)maps block index M into I(J), group index of its rows(columns)
  INTEGER,DIMENSION(:),ALLOCATABLE                :: RowGrp,ColGrp
  ! for state i that is a member of I, offs(I)=i-S, and S is the index of i within the group
  INTEGER,DIMENSION(:),ALLOCATABLE                :: offs
  ! BlkMap(i,j) maps entry H(i,j) to the block it belongs to
  INTEGER,DIMENSION(:,:),ALLOCATABLE              :: BlkMap

  ! List of all polynomial terms included
  type(TTermList),dimension(:),allocatable             :: termList
  ! Map that defines basis matrices from polynomial terms defined in termList
  type(TMaptabEnt),DIMENSION(:,:),allocatable,private  :: maptab
  ! diabatic Hamiltonian, as an expansion of basis matrices defined in maptab
  type(TDList),dimension(:,:),allocatable      :: Hd
  ! linearized Hd, with symmetry coefficients and expansion coefficients expanded and collected
  ! for raw terms to yield a contracted vector form.   dhdl provides the corresponding vector for
  ! each of the gradients in internal coordinates
  type(TDList),dimension(:,:,:),allocatable,private    :: hdl
  type(TDList),dimension(:,:,:,:),allocatable,private  :: dhdl
  ! linearized term values list
  type(TDList),dimension(:),allocatable,private        :: TValL
  ! parent term indices and reduction direction
  type(TiList),dimension(:),allocatable,private        :: ptermL
  type(TiList),dimension(:),allocatable,private        :: pdirL
  type(TiList),dimension(:),allocatable,private        :: pCntL
CONTAINS
!*****************************************************************
!*  MODULE SUBROUTINES
!*****************************************************************
 !------------------------------------------------------------------
 ! Evaluate the value of symmetrized polynomial basis or its derivative,
 ! up to arbitrary order.
 ! Values of derivatives of raw polynomial terms are first generated and
 ! stored in the register field in structure TermList.
 ! The subroutine will then go over all entries of certain order and block
 ! of $(maptab) to evaluate values/derivatives of basis matrices, each
 ! entry as a linear combination of polynomial terms.
 ! nderiv     (input) INTEGER
 !            Total number of derivatives taken
 ! dlist      (input) INTEGER,dimension(nderiv)
 !            List of coordinates to take derivatives with respect to.
 ! geom       (input) DOUBLE PRECISION,dimension(ncoords)
 !            Geometry at which value/derivative will be evaluated
 ! dval       (output) TYPE(T3DDLIST),dimensioin(nderiv:order,nblks)
 !            Matrices of values or derivatives of all basis matrices
 !            that has an order higher or equal to nderiv.  Lower order
 !            matrices are not calculated because they are zeros.
 SUBROUTINE EvaluateBasis(nderiv,dlist,dval)
  IMPLICIT NONE
  INTEGER,INTENT(IN)                                        :: nderiv
  INTEGER,DIMENSION(nderiv),INTENT(IN)                      :: dlist
  type(T3DDList),DIMENSION(nderiv:order,nblks),INTENT(OUT)  :: dval
  integer                 :: i,j,f,v,m,ll,rr
  type(TTermDef),pointer  :: pT
  type(TMTabBasis),pointer:: pM
  double precision,dimension(:,:,:),pointer :: pL

  !calculate dval using raw terms and maptab
  do i=nderiv,order
   do j=1,nblks
    ll=nl(j)
    rr=nr(j)
    allocate(dval(i,j)%List(maptab(i,j)%nBasis,ll,rr))
    pL=>dval(i,j)%List
    pL=dble(0)
    pM=>maptab(i,j)%handle
    do f=1,maptab(i,j)%nBasis
      pM=>pM%pNext
      do v=1,pM%nTerms
        pT=>pM%term(v)%p
        ! look for the term obtained by t taking all the derivatives
        do m=1,nderiv
          pT=>pT%dcTerm(dlist(m))%p
          if(.not. associated(pT))exit
        end do!m=1,ncoords
        if(.not. associated(pT))cycle
        pL(f,1:ll,1:rr)=pL(f,1:ll,1:rr)+pT%val*pM%coef(1:ll,1:rr,v)
      end do!v=1,pM%nTerms
    end do!f=1,maptab(i,j)%nBasis
   end do!j=1,nblks
  end do !i=nderiv,order
 END SUBROUTINE !EvaluateBasis
! same as evaluate basis but generates the values and all derivatives at the 
! same time
 SUBROUTINE EvaluateBasis2(val,dval)
  IMPLICIT NONE
  type(T3DDList),DIMENSION(0:order,nblks),INTENT(OUT)       :: val
  type(T3DDList),DIMENSION(ncoord,order,nblks),INTENT(OUT)  :: dval
  integer                 :: i,j,f,v,m,ll,rr
  type(TTermDef),pointer  :: pT,pTd
  type(TMTabBasis),pointer:: pM
  double precision,dimension(:,:),allocatable  :: MCoef,vsum
  double precision,dimension(:,:,:),allocatable  :: dsum
  
  !calculate dval using raw terms and maptab
  do i=0,order
   do j=1,nblks
    ll=nl(j)
    rr=nr(j)
    allocate(MCoef(ll,rr))
    allocate(vsum(ll,rr))
    allocate(dsum(ll,rr,ncoord))
    if(associated(val(i,j)%List))deallocate(val(i,j)%List)
    allocate(val(i,j)%List(maptab(i,j)%nBasis,ll,rr))
    if(i>0)then
      do m=1,ncoord
        if(associated(dval(m,i,j)%List))deallocate(dval(m,i,j)%List)
        allocate(dval(m,i,j)%List(maptab(i,j)%nBasis,ll,rr))
      end do
    end if
    pM=>maptab(i,j)%handle
    do f=1,maptab(i,j)%nBasis
      vsum = 0d0
      dsum = 0d0
      pM=>pM%pNext
      do v=1,pM%nTerms
        pT=>pM%term(v)%p
        MCoef=pM%coef(:,:,v)
        vsum = vsum + MCoef*pT%val
        ! look for the term obtained by t taking all the derivatives
        if(i>0)then
          do m=1,ncoord
            pTd=>pT%dcTerm(m)%p
            if(associated(pTd))dsum(:,:,m)=dsum(:,:,m)+pTd%val*MCoef
          end do!m=1,ncoord
        end if!i>0
      end do!v=1,pM%nTerms
      val(i,j)%List(f,:,:)=vsum
      if(i>0)then
        do m=1,ncoord
          dval(m,i,j)%List(f,:,:)=dsum(:,:,m)
        end do
      end if
    end do!f=1,maptab(i,j)%nBasis
    deallocate(MCoef)
    deallocate(vsum)
    deallocate(dsum)
   end do!j=1,nblks
  end do !i=nderiv,order
 END SUBROUTINE EvaluateBasis2
 !***********************************************************************
 ! This subroutine evaluates the values of raw polynomial terms at a 
 ! certain geometry.  Values are saved in the register elements of 
 ! structure TermList
 SUBROUTINE EvalRawTerms(geom)
  IMPLICIT NONE
  DOUBLE PRECISION,DIMENSION(ncoord),INTENT(IN)             :: geom
  integer                 :: i,j
  type(TTermDef),pointer  :: pT

  !evaluate the values of raw terms
  termList(0)%handle%pNext%val=1
  do i=1,order
    pT=>termList(i)%handle
    do j=1,termList(i)%nTerms
      pT=>pT%pNext
      pT%val=pT%dcTerm(pT%coord(i))%p%val*geom(pT%coord(i))/pT%dcCount
    end do !j=1,termList(i)%nTerms
  end do!i=1,order
 END SUBROUTINE EvalRawTerms

 !***********************************************************************
 ! This subroutine evaluates the values of raw polynomial terms at a 
 ! certain geometry using linearized storage
 SUBROUTINE EvalRawTermsL(geom)
  IMPLICIT NONE
  DOUBLE PRECISION,DIMENSION(ncoord),INTENT(IN)             :: geom
  integer                 :: i,j

  !evaluate the values of raw terms
  do i=1,order
!$OMP PARALLEL DO DEFAULT(SHARED) PRIVATE(j)
    do j=1,termList(i)%nTerms
      TValL(i)%List(j) = TValL(i-1)%List(pTermL(i)%List(j))*geom(pDirL(i)%List(j))/pCntL(i)%List(j)
    end do
!$OMP END PARALLEL DO
  end do!i=1,order
 END SUBROUTINE EvalRawTermsL

 !***********************************************************************
 ! Construct linearized Hd using Hd coefficients and symmetrized expansion 
 ! termList(i)%nterms elements will be generated for each order,block pair.  
 ! the inner product with the vector of term values will yield the value
 ! or derivative of a block of Hd.
 SUBROUTINE LinearizeHd 
  IMPLICIT NONE
  integer ::  i,j,l,r,ll,rr,l1,l2,r1,r2,v,f,ind,icor
  type(TMTabBasis),pointer:: pM
  type(TTermDef),pointer  :: pT
  double precision  :: prod
 
  if(allocated(hdl))deallocate(hdl)
  allocate(hdl(0:order,nstates,nstates))
  if(allocated(dhdl))deallocate(dhdl)
  allocate(dhdl(0:order-1,ncoord,nstates,nstates))
  do i=0,order
   do j=1,nblks
    ll=nl(j)
    rr=nr(j)
    l1=offs(RowGrp(j))+1
    l2=offs(RowGrp(j))+ll
    r1=offs(ColGrp(j))+1
    r2=offs(ColGrp(j))+rr
    do l=l1,l2
      do r=r1,r2
        if(allocated(hdl(i,l,r)%List))deallocate(hdl(i,l,r)%List)
        allocate(hdl(i,l,r)%List(termList(i)%nterms))
        hdl(i,l,r)%List=dble(0)
        if(i.eq.order)cycle
        do icor = 1,ncoord
         if(allocated(dhdl(i,icor,l,r)%List))deallocate(dhdl(i,icor,l,r)%List)
         allocate(dhdl(i,icor,l,r)%List(termList(i)%nterms)) 
         dhdl(i,icor,l,r)%List=dble(0)
        end do
      end do !r
    end do !l
    pM=>maptab(i,j)%handle
    do f=1,maptab(i,j)%nBasis
      pM=>pM%pNext
      do v=1,pM%nTerms
        do l=0,ll-1
          do r=0,rr-1 
            ind = pM%term(v)%p%index
            prod = pM%coef(1+l,1+r,v) * Hd(i,j)%List(f)
            hdl(i,l1+l,r1+r)%List(ind) = hdl(i,l1+l,r1+r)%List(ind) + prod
            if(i.eq.0) cycle
            do icor=1,ncoord
              pT=>pM%term(v)%p%dcTerm(icor)%p
              if(.not.associated(pT))cycle
              ind = pT%index
              dhdl(i-1,icor,l1+l,r1+r)%List(ind)=dhdl(i-1,icor,l1+l,r1+r)%List(ind)+prod 
            end do !icor
          end do !r
        end do !l
      end do!v=1,pM%nTerms
    end do!f=1,maptab(i,j)%nBasis
   end do!j=1,nblks
  end do !i=nderiv,order
  
  if(allocated(TValL))deallocate(TValL)
  if(allocated(ptermL))deallocate(ptermL)
  if(allocated(pdirL))deallocate(pdirL)
  if(allocated(pCntL))deallocate(pCntL)
  allocate(TValL(0:order))
  allocate(ptermL(order))
  allocate(pdirL(order))
  allocate(pCntL(order))
  allocate(TValL(0)%List(1))
  TValL(0)%List=1D0
  do i=1,order
    allocate(TValL(i)%List(termList(i)%nTerms))
    allocate(ptermL(i)%List(termList(i)%nTerms))
    allocate(pdirL(i)%List(termList(i)%nTerms))
    allocate(pCntL(i)%List(termList(i)%nTerms))
    pT=>termList(i)%handle
    do j=1,termList(i)%nTerms
      pT=>pT%pNext
      ptermL(i)%List(j)=pT%dcTerm(pT%coord(i))%p%index 
      pDirL(i)%List(j) =pT%coord(i)
      pCntL(i)%List(j) =pT%dcCount
    end do !j=1,termList(i)%nTerms
  end do!i=1,order
 END SUBROUTINE LinearizeHd
 !***********************************************************************
 SUBROUTINE filterBlock(blk,terms)
   IMPLICIT NONE
   INTEGER,INTENT(IN)  :: blk,terms(:)
   integer  :: i,nb0,nb,j,nbnew,nbtotal
   type(TMaptabEnt),allocatable,dimension(:) :: pList
   integer,allocatable,dimension(:)          :: tList
   type(TMTabBasis),pointer                  :: pM  
   nb0=0
   nbtotal=0
   do i=0,order
     nb= maptab(i,blk)%nBasis
     nbnew=0
     allocate(pList(nb))
     allocate(tList(nb))
     pM=>maptab(i,blk)%handle
     do j=1,nb
       pM=>pM%pNext
       pList(j)%handle=>pM
     end do
     do j=1,nb
       if(any(nb0+j .eq. terms))then
         nbnew=nbnew+1
         tList(nbnew)=j
       else
         deallocate(pList(j)%handle%coef)        
         deallocate(pList(j)%handle%term) 
         deallocate(pList(j)%handle) 
       end if
     end do

     if(nbnew==0)then
       nullify(maptab(i,blk)%handle%pNext)
     else
       nullify(pList(tList(nbnew))%handle%pNext)
       maptab(i,blk)%handle%pNext=>pList(tList(1))%handle
     end if
     do j=1,nbnew-1
       pList(tList(j))%handle%pNext=>pList(tList(j+1))%handle
     end do
     maptab(i,blk)%nBasis=nbnew
     nbtotal=nbtotal+nbnew
     nb0=nb0+nb
     deallocate(tList)
     deallocate(pList)
   end do
   if(nbtotal.ne.size(terms))stop "filterBlock:  Incorrect number of terms in filtered expansion."
 END SUBROUTINE filterBlock
 !***********************************************************************
 ! Directly evaluate value and derivatives of Hd, without explicitly creating
 ! basis functions.  All components of derivatives and the value of Hd are 
 ! generated in a compact manner to gain maximum advantage of shared values
 SUBROUTINE EvalHdDirect(hmat,dhmat)
  IMPLICIT NONE
  DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT)        :: hmat
  DOUBLE PRECISION,DIMENSION(ncoord,nstates,nstates),INTENT(OUT) :: dhmat

  integer                 :: i,l,r,icor
  double precision,external ::  ddot

  hmat  = dble(0)
  dhmat = dble(0)
  do i=0,order
  do l=1,nstates
     do r=l,nstates
       hmat(l,r)=hmat(l,r)+ddot(termList(i)%nterms,TValL(i)%List,int(1),hdl(i,l,r)%List,int(1))
       if(i.eq.order)cycle
       do icor = 1,ncoord
         dhmat(icor,l,r) = dhmat(icor,l,r) + &
                ddot(termList(i)%nterms,TValL(i)%List,int(1),dhdl(i,icor,l,r)%List,int(1))
       end do
     end do !r
   end do !l
  end do !i=0,order

  ! fill out the part below the diagonal
  do l=2,nstates
    do r=1,l-1
      hmat(l,r)    = hmat(r,l)
      dhmat(:,l,r) = dhmat(:,r,l)
    end do!r=1,l-1
  end do!l=1,nstates
 END SUBROUTINE
 !***********************************************************************
 ! Evaluate the value or some derivative of Hd, using the value or derivatives
 ! of basis matrices stored in $(dval), returned by EvaluateBasis() and the
 ! coefficients stored in $(Hd)
 ! nderiv   (input) INTEGER
 !          Total number of derivatives taken.
 ! dval     (input) TYPE(T3DDLIST),dimensioin(nderiv:order,nblks)
 !          Matrices of values or derivatives of all basis matrices
 !          that has an order higher or equal to nderiv, returned by EvalauteBasis()
 ! hmat     (output) DOUBLE PRECISION,dimension(nstates,nstates)
 !          Value or derivative of Hd
 SUBROUTINE EvaluateHd(nderiv,dval,hmat,morder)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                                      :: nderiv
   TYPE(T3DDList),DIMENSION(nderiv:order,nblks),INTENT(IN) :: dval
   DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT) :: hmat
   INTEGER,OPTIONAL                                        :: morder
   integer   :: i,j,f,l1,l2,r1,r2,mord
   if(present(morder))then
     mord=morder
   else
     mord=order
   end if
   hmat=dble(0)
   do i=nderiv,mord
     do j=1,nblks
       l1=offs(RowGrp(j))+1
       l2=offs(RowGrp(j))+nl(j)
       r1=offs(ColGrp(j))+1
       r2=offs(ColGrp(j))+nr(j)
       do f=1,maptab(i,j)%nBasis
         hmat(l1:l2,r1:r2)=hmat(l1:l2,r1:r2)+Hd(i,j)%List(f)*dval(i,j)%List(f,:,:)
       end do!f=1,maptab(i,j)%nBasis
     end do!j=1,nblks
   end do!i=max(nderiv,1),order
   ! fill out the part below the diagonal
   do i=2,nstates
     do j=1,i-1
       hmat(i,j)=hmat(j,i)
     end do!j=1,i-1
   end do!i=1,nstates
 END SUBROUTINE EvaluateHd

 !***********************************************************************
 ! Higher level subroutines for evaluation of Hd or its derivatives
 ! without explicitly dealing with basis matrices.
 ! *Temporary structures are created to store value or derivatives of basis
 ! matrices.  They are release upon leaving the subroutines.
 ! *These subroutines are meant to be used at geometries where the value or
 !  derivatives of Hd will only be evaluated once.  When repeated evaluation
 !  is expected, use EvaluateBasis and EvaluateHd instead.
 ! Arguments:
 ! geom      (input) DOUBLE PRECISION,dimension(ncoord)
 !           Geometry where Hd or its derivatives will be evaluated
 ! hmat      (output) DOUBLE PRECISION,dimension(nstates,nstates)
 !           Value derivative of quasi-diabatic Hamiltonian Hd
 ! icor*     (input) INTEGER
 !           Coordinate to take derivatives with respect to
 !***********************************************************************
 !Evaluate Hd without precalculated values
 SUBROUTINE makehmat(geom,hmat)
   IMPLICIT NONE
   DOUBLE PRECISION,DIMENSION(ncoord),INTENT(IN)           :: geom
   DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT) :: hmat
   type(T3DDList),DIMENSION(0:order,nblks)     :: dval
   integer,dimension(1)                        :: dlist
   CALL EvalRawTerms(geom)
   dlist = 0
   CALL EvaluateBasis(0,dlist,dval)
   CALL EvaluateHd(0,dval,hmat)
   CALL deallocDVal(dval)
 END SUBROUTINE makehmat
 !--------------------------------------------------------------
 !Evaluate derivative of Hd along direction icor
 SUBROUTINE makedhmat(geom,hmat)
   IMPLICIT NONE
   DOUBLE PRECISION,DIMENSION(ncoord),INTENT(IN)                  :: geom
   DOUBLE PRECISION,DIMENSION(ncoord,nstates,nstates),INTENT(OUT) :: hmat
   type(T3DDList),DIMENSION(order,nblks)       :: dval
   integer                                     :: i, dlist(1)

   CALL EvalRawTerms(geom)
   do  i=1,ncoord
     dlist(1) = i
     CALL EvaluateBasis(1,dlist,dval)
     CALL EvaluateHd(1,dval,hmat(i,:,:))
     CALL deallocDVal(dval)
   end do
 END SUBROUTINE makedhmat
 !--------------------------------------------------------------
 !Evaluate second order derivative of Hd with respect to icor1 and icor2
 SUBROUTINE makeddhmat(icor1,icor2,geom,hmat)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                                      :: icor1,icor2
   DOUBLE PRECISION,DIMENSION(ncoord),INTENT(IN)           :: geom
   DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT) :: hmat
   type(T3DDList),DIMENSION(2:order,nblks)     :: dval
   integer,dimension(2)                        :: dlist
   dlist=(/icor1,icor2/)
   CALL EvalRawTerms(geom)
   CALL EvaluateBasis(2,dlist,dval)
   CALL EvaluateHd(2,dval,hmat)
   CALL deallocDVal(dval)
 END SUBROUTINE makeddhmat

 !***********************************************************************
 ! add2maptab() adds a basis matrix to maptab
 ! m          (input) INTEGER
 ! n          (input) INTEGER
 !            Order and block index the matrix basis.  The basis will be
 !            added to entry of maptab accordingly.
 ! nt         (input) INTEGER
 !            Number of polynomial terms in the expansion of basis.
 ! tlist      (input) INTEGER,dimension(nt)
 !            List of terms used to expand the entries of the basis matrix.
 !            This list is shared by all entries.
 ! coefs      (input) DOUBLE PRECISION,dimension(nl,nr,nt)
 !            coefs(l,r,t) specifies the coefficient in front of term $(t)
 !            of tlist for entry ($(l),$(r)) of the basis matrix.
 SUBROUTINE add2maptab(m,n,nt,tlist,coefs)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                                      :: m,n,nt
   TYPE(pTermDef),DIMENSION(nt)                            :: tlist
   DOUBLE PRECISION,DIMENSION(GrpLen(RowGrp(n)),GrpLen(ColGrp(n)),nt),INTENT(IN)   :: coefs
   type(TMTabBasis),pointer  :: pM
   ! construct the definition of new basis matrix
   allocate(pM)
   pM%nterms=nt
   allocate(pM%term(nt))
   pM%term=tlist
   allocate(pM%coef(nl(n),nr(n),nt))
   pM%coef=coefs
   nullify(pM%pNext)
   ! add the new basis to the link table
   maptab(m,n)%nBasis=maptab(m,n)%nBasis+1
   maptab(m,n)%last%pNext=>pM
   maptab(m,n)%last=>pM
 END SUBROUTINE add2maptab

 !***********************************************************************
 ! genTermList() generates all possible polynomial terms up to given order
 ! subject to a set of linear inequality conditions C.x<rhs
 ! ncond      (input) INTEGER
 !            Number of linear inequality conditions.
 ! C          (input) INTEGER,dimension(ncond,ncoord)
 ! rhs        (input) INTEGER,dimension(ncond)
 !            C and rhs specifies the linear equality conditions.
 !            The $(i)th condition is specified by inequality
 !            dot_product(C(i,:),x)<rhs(i)
 !            where x(j) is the order of coordinate j
 SUBROUTINE genTermList(ncond,C,rhs)
  IMPLICIT NONE
  INTEGER, INTENT(IN)                        :: ncond
  INTEGER,DIMENSION(ncond,ncoord),INTENT(IN) :: C
  INTEGER,DIMENSION(ncond),INTENT(IN)        :: rhs
  integer,dimension(order)             :: tempTerm
  integer       ::  i,j,k,l,count1,count2,count_rate
  logical       ::  selTerm
  type(TTermDef),pointer :: pT
  !!!!!initialize the structure!!!!!
  call system_clock(COUNT=count1,COUNT_RATE=count_rate)
  do i=1,order
    !tempList(*,1:i)stores the definition of new terms. (*,0)is the
    !index of parent term in i-1 list.  (*,i+1) is value of dcCount
    pT=>termList(i-1)%handle
    do j=1,termList(i-1)%nTerms
      pT=>pT%pNext
      do k=1,min(pT%coord(i-1),ncoord)
        tempTerm(1:(i-1))=pT%coord(1:)
        tempTerm(i)=k
        selTerm=.true.
        do l=1,ncond
          if(sum(C(l,tempTerm(1:i)))>rhs(l))then
            selTerm=.false.
            exit
          end if
        end do!l=1,ncond
        if(selTerm)CALL addTerm(pT,k)
      end do!k=1,min(pT%coord(i-1),ncoord)
    end do!j=1,termList(i-1)%nTerms
  end do !i=2,order
  call system_clock(COUNT=count2)
  print 1001,dble(count2-count1)/count_rate
 1001 format("  Term definitions generated in ",f6.2," seconds")
 CONTAINS
   ! Add a new term to the termList
   ! The new term is defined by appending a coordinate to an existing term.
   ! PRIVATE
   ! pParent     :  Pointer to the parent lower order term.
   ! icor        :  Coordinate to append to the parent term
   SUBROUTINE addTerm(pParent,icor)
     IMPLICIT NONE
     TYPE(TTermDef),POINTER     ::  pParent
     INTEGER,INTENT(IN)         ::  icor
     type(TTermDef),pointer :: pT
     integer                :: i
     !!!Validate input!!
     if(pParent%ord>=order)RETURN
     if(.not. associated(pParent))RETURN
     if(icor<1.or. icor>pParent%coord(pParent%ord))RETURN
     !! Create the definitions of new term
     allocate(pT)
     pT%ord=pParent%ord+1
     allocate(pT%coord(pT%ord))
     pT%coord(:pParent%ord)=pParent%coord(1:)
     pT%coord(pT%ord)=icor
     !  count the number of last coordinate
     if(pParent%coord(pParent%ord)==icor)then
       pT%dcCount=pParent%dcCount+1
     else!if(pParent%coord(pParent%ord)==icor)
       pT%dcCount=1
     end if!(pParent%coord(pParent%ord)==icor)
     ! higher order terms are not defined yet
     allocate(pT%icTerm(ncoord))
     do i=1,ncoord
       Nullify(pT%icTerm(i)%p)
     end do!i=1,ncoord
     allocate(pT%dcTerm(ncoord))
     !associate the links with lower order terms
     do i=1,ncoord
       if(i==icor)then
         pT%dcTerm(i)%p=>pParent
         pParent%icTerm(i)%p=>pT
       else!if(i==icor)
         if(associated(pParent%dcTerm(i)%p))then
           pT%dcTerm(i)%p=>pParent%dcTerm(i)%p%icTerm(icor)%p
           pT%dcTerm(i)%p%icTerm(i)%p=>pT
         else!if(associated(pParent%dcTerm(i)%p))
           Nullify(pT%dcTerm(i)%p)
         end if!(associated(pParent%dcTerm(i)%p))
       end if!(i==icor)
     end do!i=1,ncoord
     Nullify(pT%pNext)
     !link the constructed node to the main link list
     termList(pT%ord)%nTerms=termList(pT%ord)%nTerms+1
     pT%index = termList(pT%ord)%nTerms
     termList(pT%ord)%last%pNext=>pT
     termList(pT%ord)%last=>pT
   END SUBROUTINE addTerm
 END SUBROUTINE genTermList

 !***********************************************************************
 ! writeHd() Exports Hd to file
 ! filename    (input) CHARACTER(255)
 !             Name of file to which Hd coefficients will be exported to.
 ! flheader    (input) CHARACTER(255)
 !             A header string that will be written to the file which
 !             should contains a line of comments that specifies contents
 !             stored in the file.
 ! writedef    (input) LOGICAL
 !             Whether or not basis and term definitions will be written
 !             to file.
 SUBROUTINE writeHd(filename,flheader,writedef)
   IMPLICIT NONE
   CHARACTER(255),INTENT(IN)        :: filename,flheader
   LOGICAL,INTENT(IN)               :: writedef
   INTEGER                          :: i,j,ios,SURFOUT
   CHARACTER(72)  :: ver
   call getver(ver)
   if(filename=='')return
   SURFOUT=getFlUnit() !obtain a file unit index
   open(unit=SURFOUT,file=trim(adjustl(filename)),access='sequential',form='formatted',&
        STATUS='REPLACE',POSITION='REWIND',ACTION='WRITE',IOSTAT=ios)
   if(ios/=0)then !check if the file is successfully opened
     stop 'writeHd: Cannot open output file for write'
     return
   end if!ios/=0
   write(SURFOUT,1000)'SURFGEN.GLOBAL Hd COEFFICIENTS FILE V:'//trim(adjustl(ver))
   write(SURFOUT,1000)flheader
   write(SURFOUT,1000)'ORDER'
   write(SURFOUT,'(I5)')order
   if(writedef)then !WRITE TERM DEFINITIONS TO FILE
      write(SURFOUT,1000) 'TERM DEFINITIONS'
   end if!(writedef)
   write(SURFOUT,1000)'COEFFICIENTS'
   ! output all coefficients
   do i = 0,order
     do j=1,nblks
       if(maptab(i,j)%nBasis>0)then
         write(SURFOUT,1003) i,j
         write(SURFOUT,1001) Hd(i,j)%List
       end if!maptab(i,j)%nBasis>0
     end do !j=1,nblks
   enddo !i=1,order
   close(SURFOUT)
   return
 1000 format(72a)
 1001 format(6(ES24.16))
 1003 format('ORDER ',I5,' BLOCK ',I5)
 END SUBROUTINE writeHd

 !***********************************************************************
 ! readHd() import Hd coefficients from file generated by writeHd
 ! filename   (input) CHARACTER(255)
 !            Name of file that contains Hd coefficients
 SUBROUTINE readHd(filename)
   IMPLICIT NONE
   CHARACTER(255),INTENT(IN)        :: filename
   INTEGER                          :: i,j,ios,SURFIN
   INTEGER                          :: i_in,j_in,order_in
   CHARACTER(255)                   :: comment,title
   CHARACTER(72)                    :: ver,verhd

   call getver(ver)

   if(filename=='')return
   SURFIN=getFLUnit() !obtain file unit index
   open(UNIT=SURFIN,FILE=trim(adjustl(filename)),ACCESS='sequential',&
       form='formatted',POSITION='REWIND',ACTION='READ',STATUS='OLD',IOSTAT=ios)
   if(ios/=0)then
     stop 'readHd: Cannot open input file'
     return
   end if!(ios/=0)
   read(SURFIN,1000)title!'SURFGEN.GLOBAL Hd COEFFICIENTS FILE'
   read(SURFIN,1000)comment!flheader
   verhd = trim(adjustl(title(39:)))
   print *,"  Reading Hd from file ",trim(adjustl(filename))
   print "(A)","     Program version: ["//trim(verhd)//"]"
   if(trim(verhd)/=trim(adjustl(ver)))print "(5x,A)",&
          "Warning: the file was generated by a different version of surfgen"
   print *,"    Description:",trim(adjustl(comment))
   read(SURFIN,1000)comment!'ORDER'
   read(SURFIN,*)order_in
   print *,"    Order of Polynomial Contained in File:",order_in
   if(order_in<0)stop 'INVALID VALUE FOR order'
   if(order_in>order)then
     print *,'Input file truncated to the same order as Hd.'
     order_in=order
   end if !(order_in>order)
   read(SURFIN,1000)comment
   if(comment=='TERM DEFINITIONS')then
     read(SURFIN,1000)comment
   end if!(comment=='TERM DEFINITIONS')
   if(comment/='COEFFICIENTS')then
     stop 'readHd: coefficients block expected'
   end if!(comment/='CONSTANT COEFFICIENTS')
   ! clean hd
   do i = 0,order_in
     do j=1,nblks
       if(maptab(i,j)%nBasis>0)then
         read(SURFIN,1003,IOSTAT=ios)i_in,j_in
         if(ios/=0)then
            print *,"readHd: error reading Hd data file. IOSTAT=",ios
            print *,"   order=",i,"  iblk=",j
            return
         end if!ios/=0
         if(i_in/=i.or.j_in/=j)then
            print *,"readHd:  Inconsistency in Hd data file."
            print *,"  expecting:  order=",i,", iblk=",j
            print *,"  input file: order=",i_in,", iblk=",j_in
            print *,"Failed to import Hd data from file."
            return
         end if!(i_in/=i.or.j_in/=j)
         READ(SURFIN,*,IOSTAT=ios) Hd(i,j)%List
         if(ios/=0)then
            print *,"readHd: error reading Hd data file. IOSTAT=",ios
            print *,"   order=",i,"  iblk=",j
            return
         end if!ios/=0
       end if!(maptab(i,j)%nBasis>0)
     end do !j=1,nblks
   enddo !i=1,order

   close(SURFIN)
   print *,'  Hd Data Imported.'
   call LinearizeHd
   print *,'  Contracted vector form generated.'
 1000 format(72a)
 1003 format(7X,I5,7X,I5)
 END SUBROUTINE readHd

 !***********************************************************************
 !This subroutine generates a map of all the unknown coefficient of certain order
 !MinOrder         :  The minimum order that will be put into the list.
 !MaxOrder         :  The maximum order that will be put into the list.
 !coefMap(nCoef,3) :  (/order,iblk,iBasis/) of all the coefficients
 !LDM              :  Leading dimension of array coefMap.  LDM>=Total number of
 !                    coefficients between the specified order
 SUBROUTINE makeCoefMap(MinOrder,MaxOrder,coefMap,LDM)
   implicit none
   integer,intent(IN)                       :: MinOrder,MaxOrder,LDM
   integer,dimension(LDM,3),intent(out)     :: coefMap
   integer  :: i,j,k,cCount
   cCount=0
   do i=MinOrder,MaxOrder
     do j=1,nblks
       do k=1,nBasis(i,j)
         cCount=cCount+1
         if(cCount>LDM)stop 'makeCoefMap: LDM<Number of coefficients!'
         coefMap(cCount,:)=(/i,j,k/)
       end do
     end do!j=1,nblks
   end do!i=1,MaxOrder
 END SUBROUTINE makeCoefMap

 !***********************************************************************
 !This subroutine updates Hd coefficients according to a linear array
 !and the list that locates all these coefficients in Hd.
 SUBROUTINE updateHd(coefs,coefMap,ncoef)
   IMPLICIT NONE
   DOUBLE PRECISION,DIMENSION(ncoef),INTENT(IN)  :: coefs
   Integer,dimension(nCoef,3),intent(IN)         :: coefMap
   INTEGER,INTENT(IN)                            :: nCoef

   integer  ::  i,ordr,iblk,ibss
   do i=1,nCoef
      ordr=coefMap(i,1)
      iblk=coefMap(i,2)
      iBss=coefMap(i,3)
      Hd(ordr,iblk)%List(iBss)=coefs(i)
   end do
 END SUBROUTINE updateHd

 !***********************************************************************
 !This subroutine extracts Hd coefficients into a linear array
 !and the list that locates all these coefficients in Hd.
 SUBROUTINE extractHd(coefs,coefMap,ncoef)
   IMPLICIT NONE
   DOUBLE PRECISION,DIMENSION(ncoef),INTENT(OUT) :: coefs
   Integer,dimension(nCoef,3),intent(IN)         :: coefMap
   INTEGER,INTENT(IN)                            :: nCoef

   integer  ::  i,ordr,iblk,ibss
   do i=1,nCoef
      ordr=coefMap(i,1)
      iblk=coefMap(i,2)
      iBss=coefMap(i,3)
      coefs(i)=Hd(ordr,iblk)%List(iBss)
   end do
 END SUBROUTINE extractHd

 !***********************************************************************
 ! Link entries in maptab from one block to another.
 ! This is used to clone blocks with identical symmetry properties
 ! The links to the handle will simply be copied over.  The last pointer
 ! will not be copied since the cloned tree is not intended to be modified. 
 SUBROUTINE lnBlock(fromBlk,toBlk)
   IMPLICIT NONE
   INTEGER, intent(IN)  :: fromBlk,toBlk
   integer  :: i
   do i=0,order
     maptab(i,toBlk)%handle  => maptab(i,fromBlk)%handle
     maptab(i,toBlk)%nBasis  =  maptab(i,fromBlk)%nBasis
     nullify(maptab(i,toBlk)%last)
   end do
 END SUBROUTINE lnBlock

 !***********************************************************************
 ! Clear and initialize all global constructs, including Hd, termList and
 ! maptab. Also generates mappings between blocks, groups and states
 ! NGrp     (input) INTEGER
 !          Number of state groups.
 ! LenGrp   (input) INTEGER,dimension(NGrp)
 !          Number of states contained in each group
 SUBROUTINE initGrps(NGrp,LenGrp)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                :: NGrp
   INTEGER,DIMENSION(NGrp),INTENT(IN):: LenGrp
   integer                  ::  i,j,m
   if(NGrp<1)stop "initGrp: Invalid number of groups."
   CALL cleanHdData()
   nstates=sum(LenGrp)
   ! Generate mappings between states and groups
   nGroups=NGrp
   nblks=nGroups*(nGroups+1)/2
   allocate(GrpLen(NGrp))
   allocate(offs(NGrp))
   allocate(RowGrp(nblks))
   allocate(ColGrp(nblks))
   allocate(BlkMap(nstates,nstates))
   BlkMap=0
   GrpLen=LenGrp
   m=0 !m is the index of block
   offs(1)=0
   do i=2,nGroups
     offs(i)=offs(i-1)+GrpLen(i-1)
   end do !i=2,nGroups
   do i=1,nGroups
     do j=i,nGroups
       m=m+1
       RowGrp(m)=i
       ColGrp(m)=j
       BlkMap(offs(i)+1:offs(i)+GrpLen(i),offs(j)+1:offs(j)+GrpLen(j))=m
       BlkMap(offs(j)+1:offs(j)+GrpLen(j),offs(i)+1:offs(i)+GrpLen(i))=m
     end do!j=i,nGroups
   end do !i=1,nGroups
 END SUBROUTINE initGrps
 SUBROUTINE initHd()
   IMPLICIT NONE
   integer                  ::  i,j
   type(TTermDef),pointer   :: pT
   !initialize termList
   allocate(termList(0:order))
   do i=0,order
     allocate(termList(i)%handle)
     termList(i)%last=>termList(i)%handle
     nullify(termList(i)%handle%pNext)
   end do!i=0,order
   !!!!construct 0th order list!!!!!!!!
   allocate(termList(0)%handle%pNext) !
   termList(0)%nTerms=1               !
   pT=>termList(0)%handle%pNext       !
   termList(0)%last=>pT               !
   pT%ord=0                           !
   pT%index=1                         !
   pT%dcCount=0                       !
   pT%val=dble(1)                     !
   allocate(pT%coord(0:0))            !
   pT%coord(0)=ncoord+1               !
   allocate(pT%icTerm(ncoord))        !
   allocate(pT%dcTerm(ncoord))        !
   nullify(pT%pNext)                  !
   do i=1,ncoord                      !
     nullify(pT%dcTerm(i)%p)          !
     nullify(pT%icTerm(i)%p)          !
   end do!i=1,ncoord                  !
   ! Initialize Maptab
   allocate(maptab(0:order,nblks))
   do i=0,order
     do j=1,nblks
       allocate(maptab(i,j)%handle)
       nullify(maptab(i,j)%handle%pNext)
       maptab(i,j)%last=>maptab(i,j)%handle
       maptab(i,j)%nBasis=0
     end do!j=1,nblks
   end do!i=0,order
   ! Initialize global array Hd,hdl and dhdl
   allocate(Hd(0:order,nblks))
 END SUBROUTINE initHd

 !***********************************************************************
 ! get an available UNIT index for input/output
 FUNCTION getFLUnit() RESULT(UNIT)
   IMPLICIT NONE
   INTEGER         :: UNIT
   integer         :: i
   logical         :: unitex,unitop
   UNIT=0
   do i=15,99999
     inquire(UNIT=i,EXIST=unitex,OPENED=unitop)
     if(unitex .and. .not. unitop)then
       UNIT=i
       exit
     end if!(unitex .and. .not. unitop)
   end do!i=10,99
   if(UNIT==0)stop "getFLUnit:  failed to find an available unit."
 END FUNCTION getFLUnit

 !***********************************************************************
 ! Release memory occupied by basis value storage array
 SUBROUTINE deallocDVal(dval)
   IMPLICIT NONE
   TYPE(T3DDList),DIMENSION(:,:),INTENT(INOUT) :: dval
   integer :: i,j,il,iu,jl,ju
   il=LBOUND(dval,1)
   iu=UBOUND(dval,1)
   jl=LBOUND(dval,2)
   ju=UBOUND(dval,2)
   do i=il,iu
     do j=jl,ju
       if(associated(dval(i,j)%List))deallocate(dval(i,j)%List)
     end do!j=jl,ju
   end do!i=il,iu
 END SUBROUTINE deallocDVal

 !***********************************************************************
 ! clean up all global arrays including Hd, termList maptab and mappings
 ! between blocks and states
 SUBROUTINE cleanHdData
   IMPLICIT NONE
   type(TMTabBasis),pointer :: pM,pNext
   type(TTermDef),pointer   :: pT,pNextT
   integer  ::  i,j,status,k
   ! CLEAN UP MAPPINGS BETWEEN BLOCKS AND STATES
   if(allocated(GrpLen))deallocate(GrpLen)
   if(allocated(RowGrp))deallocate(RowGrp)
   if(allocated(ColGrp))deallocate(ColGrp)
   if(allocated(offs))deallocate(offs)
   if(allocated(BlkMap))deallocate(BlkMap)
   ! Clean up Hd
   if(allocated(Hd))then
     do i=lbound(Hd,1),ubound(Hd,1)
       do j=lbound(Hd,2),ubound(Hd,2)
         if(allocated(Hd(i,j)%List))deallocate(Hd(i,j)%List,STAT=status)
         if(status/=0)print *,"ERROR: failed to deallocate Hd(",i,",",j,")%List. STAT=",status
       end do !j=lbound(Hd,2),ubound(Hd,2)
     end do !i=lbound(Hd,1),ubound(Hd,1)
     deallocate(Hd,STAT=status)
     if(status/=0)print *,"ERROR: failed to deallocate Hd.  STAT=",status
   end if!allocated(Hd)
   ! Clean up Maptab
   if(allocated(maptab))then
     do i=lbound(maptab,1),ubound(maptab,1)
       do j=lbound(maptab,2),ubound(maptab,2)
         if(.not.associated(maptab(i,j)%handle))cycle
         do k=lbound(maptab,2),ubound(maptab,2)
           if (k==j)cycle
           if(associated(maptab(i,j)%handle,maptab(i,k)%handle))nullify(maptab(i,k)%handle)
         end do
         pM=>maptab(i,j)%handle
         do while(associated(pM))
           if(allocated(pM%coef))deallocate(pM%coef)
           if(allocated(pM%term))deallocate(pM%term)
           pNext=>pM%pNext
           deallocate(pM,STAT=status)
           if(status/=0)print *,"ERROR: failed to deallocate term from",&
                    " maptab(",i,",",j,"). STAT=",status
           pM=>pNext
         end do!while(associated(pM))
       end do !j=lbound(maptab,2),ubound(maptab,2)
     end do ! i=lbound(maptab,1),ubound(maptab,1)
     deallocate(maptab,STAT=status)
     if(status/=0)print *,"ERROR: failed to deallocate maptab. STAT=",status
   end if!(allocated(maptab)
   if(allocated(termList))then
     do i=0,order
       pT=>termList(i)%handle
       do while(associated(pT))
         pNextT=>pT%pNext
         if(allocated(pT%coord))deallocate(pT%coord)
         if(allocated(pT%icTerm))deallocate(pT%icTerm)
         if(allocated(pT%dcTerm))deallocate(pT%dcTerm)
         deallocate(pT)
         pT=>pNextT
       end do!while(associated(pT))
     end do!i=1,order
   deallocate(termList,STAT=status)
   if(status/=0)print *,"ERROR: failed to deallocate termList. STAT=",status
   end if!(allocated(termList))
 END SUBROUTINE cleanHdData
 !***********************************************************************
 ! nl/nr returns the number of rows/columns of a certain block
 PURE FUNCTION nl(b)
   INTEGER            :: nl
   INTEGER,INTENT(IN) :: b
   nl=GrpLen(RowGrp(b))
 END FUNCTION nl
 PURE FUNCTION nr(b)
   INTEGER            :: nr
   INTEGER,INTENT(IN) :: b
   nr=GrpLen(ColGrp(b))
 END FUNCTION nr
 !***********************************************************************
 ! nbasis return the number of basis matrices of a certain order and block
 PURE FUNCTION nBasis(ord,blk)
   INTEGER,INTENT(IN)   :: ord,blk
   INTEGER              :: nBasis
   nBasis=maptab(ord,blk)%nBasis
 END FUNCTION nBasis
 
 !***********************************************************************
 ! nBasBlk return the total number of basis matrices of a certain block
 PURE FUNCTION nBasBlk(blk)
   INTEGER,INTENT(IN)   :: blk
   INTEGER              :: nBasBlk
   integer :: i
   nBasBlk=0
   do i=0,order
     nBasBlk=nBasBlk+maptab(i,blk)%nBasis
   end do
 END FUNCTION nBasBlk
 
 SUBROUTINE allocateHd(eguess)
  implicit none
  integer          :: i,j
  double precision,dimension(nGroups),intent(in) :: eguess
  do i=0,order
    do j=1,nblks
      allocate(Hd(i,j)%List(maptab(i,j)%nBasis))
      Hd(i,j)%List=dble(0)
    end do
  end do
  do i=1,nblks
    if(RowGrp(i)==ColGrp(i))then
      Hd(0,i)%List=eguess(RowGrp(i))
    end if
  end do
 END SUBROUTINE allocateHd


 !***********************************************************************
 ! Directly evaluate value and derivatives of Hd, without explicitly creating
 ! basis functions.  All components of derivatives and the value of Hd are 
 ! generated in a compact manner to gain maximum advantage of shared values
 SUBROUTINE EvalHdDirectOld(hmat,dhmat)
  IMPLICIT NONE
  DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT)        :: hmat
  DOUBLE PRECISION,DIMENSION(ncoord,nstates,nstates),INTENT(OUT) :: dhmat

  integer                 :: i,j,f,v,m,l1,l2,r1,r2,ll,rr
  type(TMTabBasis),pointer:: pM
  type(TTermDef),pointer  :: pT
  double precision   ::  MSum(nstates,nstates)

  hmat  = dble(0)
  dhmat = dble(0)
  do i=0,order
   do j=1,nblks
    ll=nl(j)
    rr=nr(j)
    l1=offs(RowGrp(j))+1
    l2=offs(RowGrp(j))+ll
    r1=offs(ColGrp(j))+1
    r2=offs(ColGrp(j))+rr
    pM=>maptab(i,j)%handle
    do f=1,maptab(i,j)%nBasis
      pM=>pM%pNext

      MSum = dble(0)                      ! calculate Hd
      do v=1,pM%nTerms
        MSum(l1:l2,r1:r2)=MSum(l1:l2,r1:r2) + pM%term(v)%p%val * pM%coef(1:ll,1:rr,v)
      end do!v=1,pM%nTerms
      hmat(l1:l2,r1:r2)=hmat(l1:l2,r1:r2)+Hd(i,j)%List(f)*MSum(l1:l2,r1:r2)
      if(i>0)then
        do m=1,ncoord                       ! calculate dHd
          MSum = dble(0)
          do v=1,pM%nTerms
            pT=>pM%term(v)%p%dcTerm(m)%p
            if(.not.associated(pT))cycle
            MSum(l1:l2,r1:r2)=MSum(l1:l2,r1:r2) + pT%val * pM%coef(1:ll,1:rr,v)
          end do!v=1,pM%nTerms
          dhmat(m,l1:l2,r1:r2)=dhmat(m,l1:l2,r1:r2)+Hd(i,j)%List(f)*MSum(l1:l2,r1:r2)
        end do !m=1,ncoord
      end if
    end do!f=1,maptab(i,j)%nBasis
   end do!j=1,nblks
  end do !i=nderiv,order

   ! fill out the part below the diagonal
   do i=2,nstates
     do j=1,i-1
       hmat(i,j)    = hmat(j,i)
       dhmat(:,i,j) = dhmat(:,j,i)
     end do!j=1,i-1
   end do!i=1,nstates
 END SUBROUTINE  EvalHdDirectOld
 !***********************************************************************
 !This subroutine updates Hd coefficients according to a linear array
 !and the list that locates all these coefficients in Hd.
 SUBROUTINE getHdvec(coefs,coefMap,ncoef)
   IMPLICIT NONE
   DOUBLE PRECISION,DIMENSION(ncoef),INTENT(OUT) :: coefs
   Integer,dimension(nCoef,3),intent(IN)         :: coefMap
   INTEGER,INTENT(IN)                            :: nCoef

   integer  ::  i,ordr,iblk,ibss
   do i=1,nCoef
      ordr=coefMap(i,1)
      iblk=coefMap(i,2)
      iBss=coefMap(i,3)
      coefs(i) = Hd(ordr,iblk)%List(iBss)
   end do
 END SUBROUTINE getHdvec
 !***********************************************************************
 ! this subroutine sets the coefficients of Hd for a certain block/order
 SUBROUTINE putHdCoef(ord,blk,coef)
   IMPLICIT NONE
   DOUBLE PRECISION, DIMENSION(:), INTENT(IN) :: coef
   INTEGER,INTENT(IN)                         :: ord,blk
   Hd(ord,blk)%List=coef
 END SUBROUTINE putHdCoef
 !***********************************************************************
 ! this subroutine extracts the coefficients of Hd for a certain block/order
 SUBROUTINE getHdCoef(ord,blk,coef)
   IMPLICIT NONE
   DOUBLE PRECISION, DIMENSION(:), INTENT(OUT) :: coef
   INTEGER,INTENT(IN)                          :: ord,blk
   coef = Hd(ord,blk)%List
 END SUBROUTINE getHdCoef  
 !***********************************************************************
 ! this subroutine sets the coefficients of Hd for a certain block
 SUBROUTINE putHdBlock(blk,coef)
   IMPLICIT NONE
   DOUBLE PRECISION, DIMENSION(:), INTENT(IN) :: coef
   INTEGER,INTENT(IN)                         :: blk
   integer :: i,m1,m2
   m1=0
   do i=0, order
     m2=m1+maptab(i,blk)%nBasis
     Hd(i,blk)%List=coef(m1+1:m2)
     m1=m2
   end do
 END SUBROUTINE putHdBlock
 !***********************************************************************
 ! this subroutine extracts the coefficients of Hd for a certain block
 SUBROUTINE getHdBlock(blk,coef)
   IMPLICIT NONE
   DOUBLE PRECISION, DIMENSION(:), INTENT(OUT) :: coef
   INTEGER,INTENT(IN)                          :: blk
   integer :: i,m1,m2
   m1=0
   do i=0, order
     m2=m1+maptab(i,blk)%nBasis
     coef(m1+1:m2)=Hd(i,blk)%List
     m1=m2
   end do
 END SUBROUTINE getHdBlock
 !***********************************************************************
 ! Evaluate value and first derivatives of Hd using packed value matrices
 SUBROUTINE EvaluateHd2(npoints,ipt,nvibs,nvibpt,hmat,dhmat,wval,dwval,morder)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                                :: npoints,ipt,nvibs,nvibpt
   TYPE(TDList),DIMENSION(0:order,nblks),INTENT(IN)  :: wval
   TYPE(TDList),DIMENSION(1:order,nblks),INTENT(IN)  :: dwval
   DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT)         :: hmat
   DOUBLE PRECISION,DIMENSION(nvibs,nstates,nstates),INTENT(OUT)   :: dhmat
   INTEGER,OPTIONAL                                        :: morder
   
   integer   :: i,j,l1,l2,r1,r2,nf,l,r,m,count1,count2,pv,mord

   if(present(morder))then
     mord=morder
   else
     mord=order
   end if

   hmat=dble(0)
   dhmat = dble(0)
   pv=npoints*nvibs
   do i=0,mord
     do j=1,nblks
       l1=offs(RowGrp(j))+1
       l2=offs(RowGrp(j))+nl(j)
       r1=offs(ColGrp(j))+1
       r2=offs(ColGrp(j))+nr(j)
       nf=maptab(i,j)%nBasis
       count1=0
       count2=0
       do r=r1,r2
         do l=l1,l2
           hmat(l,r)=hmat(l,r)+dot_product(Hd(i,j)%List,wval(i,j)%List(count1+ipt:count1+ipt+(nf-1)*npoints:npoints))
           if(i>0)then
             count2 = count2+ipt
             do m=1,nvibpt
               dhmat(m,l,r)=dhmat(m,l,r)+dot_product(Hd(i,j)%List,dwval(i,j)%List(count2:count2+(nf-1)*pv:pv))
               count2 = count2+npoints
             end do
           end if
           count1=count1+npoints*nf
           count2=count1*nvibs
         end do! l=l1,l2
       end do! r=r1,r2
     end do!j=1,nblks
   end do!i=max(nderiv,1),order
   ! fill out the part below the diagonal
   do i=2,nstates
     do j=1,i-1
       hmat(i,j)=hmat(j,i)
       dhmat(:,i,j)=dhmat(:,j,i)
     end do!j=1,i-1
   end do!i=1,nstates
 END SUBROUTINE EvaluateHd2
!---------------------------------------------
! evaluate Hd at data points from precalculated values of basis functions.   
! This subroutine uses the reconstructed basis function with linear dependency removed.
! The transformation is generated by genBasis and stored in TBas.  The transformed basis is stored in WVals
SUBROUTINE EvaluateHd3 (hvec,nBas,npoints,ipt,nvibs,hmat,dhmat,wmat)
   IMPLICIT NONE
   INTEGER,INTENT(IN)                                              :: npoints,ipt,nvibs,nBas(nblks)
   DOUBLE PRECISION,DIMENSION(*),INTENT(IN)                        :: hvec
   TYPE(T2DDList),DIMENSION(nblks),INTENT(IN)                      :: wmat
   DOUBLE PRECISION,DIMENSION(nstates,nstates),INTENT(OUT)         :: hmat
   DOUBLE PRECISION,DIMENSION(nvibs,nstates,nstates),INTENT(OUT)   :: dhmat

   integer   :: i,j,l1,l2,r1,r2,nf,l,r,m,count1,pv

   hmat=dble(0)
   dhmat = dble(0)
   pv=npoints*nvibs
   i = 0
   do j=1,nblks
     l1=offs(RowGrp(j))+1
     l2=offs(RowGrp(j))+nl(j)
     r1=offs(ColGrp(j))+1
     r2=offs(ColGrp(j))+nr(j)
     nf=nBas(j)
     if(nf.eq.0)cycle
     count1=(ipt-1)*(nvibs+1)+1
     do l=l1,l2
       do r=r1,r2
         hmat(l,r)=hmat(l,r)+dot_product(hvec(i+1:i+nf),wmat(j)%List(count1,:))
         do m=1,nvibs
           dhmat(m,l,r)=dhmat(m,l,r)+dot_product(hvec(i+1:i+nf),wmat(j)%List(count1+m,:))
         end do
         count1=count1+npoints*(nvibs+1)
       end do! r=r1,r2
     end do! l=l1,l2
     i = i+nBas(j)
   end do!j=1,nblks
   ! fill out the part below the diagonal
   do i=2,nstates
     do j=1,i-1
       hmat(i,j)=hmat(j,i)
       dhmat(:,i,j)=dhmat(:,j,i)
     end do!j=1,i-1
   end do!i=1,nstates
END SUBROUTINE EvaluateHd3
!---------------------------------------------
! generated basis values and derivatives in fitting coordinates for a 
! specific block.  the values are directly filled in to data matrix V
 SUBROUTINE EvaluateVal(V,iBlk,nvibs,npoints,ptid,bmat)
  IMPLICIT NONE
  DOUBLE PRECISION,INTENT(INOUT),DIMENSION(:,:) :: V
  INTEGER,INTENT(IN)                              :: iBlk,nvibs,npoints,ptid
  DOUBLE PRECISION,INTENT(IN),DIMENSION(:,:) :: bmat

  integer                 :: i,f,t,m,ll,rr, n, lr,j,shift,stride,n1
  type(TTermDef),pointer  :: pT,pTd
  type(TMTabBasis),pointer:: pM
  double precision,dimension(:),allocatable  :: MCoef,vsum,dsumb
  double precision,dimension(:,:),allocatable  :: dsum
  
  ! ll,rr is the dimensionality of current basis block
  ! lr is the size (ll*rr) of the current basis block
  ll=nl(iBlk)
  rr=nr(iBlk)
  lr = ll*rr
  stride=npoints*(nvibs+1)
  shift=(ptid-1)*(nvibs+1)
  allocate(MCoef(lr))
  allocate(vsum(lr))
  allocate(dsum(lr,ncoord))
  allocate(dsumb(ncoord))
  ! cycle through all terms and evaluate
  ! n2 is the index of basis
  n = 1
  do i=0,order
    pM=>maptab(i,iBlk)%handle
    do f=1,maptab(i,iBlk)%nBasis
      vsum = 0d0  ! vsum is the value of the current basis matrix
      dsum = 0d0  ! dsum is the derivative of the current basis matrix in nacent coordinates
      pM=>pM%pNext
      do t=1,pM%nTerms
        pT=>pM%term(t)%p
        CALL DCOPY(lr,pM%coef(1,1,t),int(1),MCOef,int(1))
        CALL DAXPY(lr,pT%val,MCoef,int(1),vsum,int(1))
        !vsum = vsum + MCoef*pT%val
        ! look for the term obtained by t taking all the derivatives
        if(i>0)then
          do m=1,ncoord
            pTd=>pT%dcTerm(m)%p
            if(associated(pTd))dsum(:,m)=dsum(:,m)+pTd%val*MCoef
          end do!m=1,ncoord
        end if!i>0
      end do!t=1,pM%nTerms
      n1=1+shift
      do j=1,lr
        V(n1,n)=vsum(j)
        if(i>0)then
          dsumb=dsum(j,:)
          CALL DGEMV('T',ncoord,nvibs,1d0,bmat,ncoord,dsumb,1,0d0,V(n1+1:n1+nvibs,n),1)
        else
          V(n1+1:n1+nvibs,n) = 0d0
        end if
        n1=n1+stride
      end do!j
      n = n + 1 
    end do!f=1,maptab(i,iBlk)%nBasis
  end do !i=0,order
  deallocate(MCoef)
  deallocate(vsum)
  deallocate(dsum)
 END SUBROUTINE EvaluateVal
END MODULE HdDATA
